import {
  fieldMaxLength,
  isTododdleSupportError,
  validateReport,
  type Config,
  type FieldDefinition,
  type ReportContext,
  type Reporter,
  type ReportInput,
  type ReportResult,
  type ReportType,
  type TododdleSupport,
} from '@krffl/tododdle-support';
import { useCallback, useEffect, useRef, useState, type ReactNode } from 'react';
import {
  ActivityIndicator,
  Image,
  KeyboardAvoidingView,
  Modal,
  Platform,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';
import { attachmentFromUri, type ImageSource } from './attachments';
import { platformContext } from './context';

export interface ReportSheetLabels {
  cancel: string;
  close: string;
  retry: string;
  sending: string;
  type: string;
  addScreenshot: string;
  removeScreenshot: string;
  screenshot: string;
  loadFailed: string;
  sendFailed: string;
  chooseOption: string;
}

export const defaultReportSheetLabels: ReportSheetLabels = {
  cancel: 'Cancel',
  close: 'Close',
  retry: 'Try again',
  sending: 'Sending…',
  type: 'Type',
  addScreenshot: 'Add screenshot',
  removeScreenshot: 'Remove screenshot',
  screenshot: 'Screenshot',
  loadFailed: 'The report form could not be loaded. Check the connection and try again.',
  sendFailed: 'The report could not be sent. Please try again.',
  chooseOption: 'Choose one',
};

export interface ReportSheetProps {
  /** A client from `createTododdleSupport`. */
  client: TododdleSupport;
  visible: boolean;
  /** Called when the person closes the sheet, after sending or not. */
  onClose: () => void;
  /** Called when the report is received or queued. */
  onSubmitted?: (result: ReportResult) => void;
  /** The host app's version and build. Added to the report context. */
  appVersion?: string;
  build?: string;
  /** More context, such as `screen` or `extra`. Nothing else is collected. */
  context?: ReportContext;
  /** Optional, unverified reporter details the app already knows. */
  reporter?: Reporter;
  defaultType?: ReportType;
  /**
   * An image the app offers to attach, for example a screenshot it took when the person tapped
   * "Report a problem". The person sees a preview and can remove it. The SDK never captures one.
   */
  screenshot?: ImageSource | null;
  /** Shows an "Add screenshot" button. Return the chosen image, or null if the person cancels. */
  onRequestScreenshot?: () => Promise<ImageSource | null>;
  labels?: Partial<ReportSheetLabels>;
}

type Phase = 'loading' | 'load-failed' | 'form' | 'sending' | 'done';

const imageTypes = new Set(['image/png', 'image/jpeg', 'image/webp', 'image/gif']);

/** A modal sheet that renders the project's report form and sends the report. */
export function ReportSheet(props: ReportSheetProps): ReactNode {
  const { client, visible, onClose } = props;
  const labels = { ...defaultReportSheetLabels, ...props.labels };
  const [config, setConfig] = useState<Config | null>(null);
  const [phase, setPhase] = useState<Phase>('loading');
  const [type, setType] = useState<ReportType | null>(null);
  const [title, setTitle] = useState('');
  const [description, setDescription] = useState('');
  const [fields, setFields] = useState<Record<string, string>>({});
  const [screenshot, setScreenshot] = useState<ImageSource | null>(null);
  const [errors, setErrors] = useState<Record<string, string>>({});
  const [formError, setFormError] = useState<string | null>(null);
  const loadId = useRef(0);

  const load = useCallback(() => {
    const id = (loadId.current += 1);
    setPhase('loading');
    client.getConfig().then(
      (loaded) => {
        if (id !== loadId.current) return;
        setConfig(loaded);
        setType((current) => current ?? pickType(loaded, props.defaultType));
        setPhase('form');
      },
      () => {
        if (id === loadId.current) setPhase('load-failed');
      },
    );
  }, [client, props.defaultType]);

  useEffect(() => {
    if (!visible) return;
    setTitle('');
    setDescription('');
    setFields({});
    setErrors({});
    setFormError(null);
    setType(null);
    setScreenshot(props.screenshot ?? null);
    load();
    // Reset only when the sheet opens, not when the parent re-renders with new callbacks.
  }, [visible]);

  const theme = config?.theme;
  const radius = theme?.corners === 'square' ? 0 : 12;
  const accent = theme?.accent ?? '#1d1d1f';
  const onAccent = theme?.onAccent ?? '#ffffff';
  const attachmentRules = config?.form.attachments;
  const canAttachImages =
    !!attachmentRules?.enabled &&
    attachmentRules.maxCount > 0 &&
    attachmentRules.contentTypes.some((contentType) => imageTypes.has(contentType));

  async function send() {
    if (!config || !type || phase === 'sending') return;
    setFormError(null);
    const input: ReportInput = {
      type,
      title: config.form.title?.enabled ? title : undefined,
      description,
      fields,
      context: { ...platformContext({ appVersion: props.appVersion, build: props.build }), ...props.context },
      reporter: props.reporter,
    };
    const localErrors = validateReport(config, input);
    if (Object.keys(localErrors).length > 0) {
      setErrors(localErrors);
      return;
    }
    setErrors({});
    setPhase('sending');
    try {
      if (screenshot && canAttachImages) input.attachments = [await attachmentFromUri(screenshot)];
      const result = await client.report(input, { config });
      props.onSubmitted?.(result);
      setPhase('done');
    } catch (error) {
      setPhase('form');
      const fieldErrors = isTododdleSupportError(error) ? error.fields : {};
      if (Object.keys(fieldErrors).length > 0) setErrors(fieldErrors);
      else setFormError(labels.sendFailed);
    }
  }

  async function addScreenshot() {
    if (!props.onRequestScreenshot) return;
    const chosen = await props.onRequestScreenshot();
    if (chosen) setScreenshot(chosen);
  }

  const button = (label: string, onPress: () => void, primary = false, disabled = false) => (
    <Pressable
      accessibilityRole="button"
      accessibilityState={{ disabled }}
      disabled={disabled}
      onPress={onPress}
      style={[
        styles.button,
        { borderRadius: radius / 2 },
        primary ? { backgroundColor: accent, borderColor: accent } : null,
        disabled ? styles.disabled : null,
      ]}
    >
      <Text style={[styles.buttonText, primary ? { color: onAccent } : null]}>{label}</Text>
    </Pressable>
  );

  let body: ReactNode;
  if (phase === 'loading' || !config) {
    body =
      phase === 'load-failed' ? (
        <View style={styles.centered}>
          <Text accessibilityRole="alert" style={styles.message}>
            {labels.loadFailed}
          </Text>
          <View style={styles.actions}>
            {button(labels.close, onClose)}
            {button(labels.retry, load, true)}
          </View>
        </View>
      ) : (
        <View style={styles.centered}>
          <ActivityIndicator accessibilityLabel="Loading" />
        </View>
      );
  } else if (phase === 'done') {
    body = (
      <View style={styles.centered}>
        <Text accessibilityRole="header" style={styles.title}>
          {config.wording.thankYouTitle}
        </Text>
        <Text style={styles.message}>{config.wording.thankYouMessage}</Text>
        <View style={styles.actions}>{button(labels.close, onClose, true)}</View>
      </View>
    );
  } else {
    const { form, wording, project } = config;
    const sending = phase === 'sending';
    body = (
      <ScrollView contentContainerStyle={styles.content} keyboardShouldPersistTaps="handled">
        <View style={styles.header}>
          {isHttpsUrl(project.logoUrl) ? (
            <Image source={{ uri: project.logoUrl }} style={styles.logo} accessibilityIgnoresInvertColors />
          ) : null}
          <Text accessibilityRole="header" style={styles.title}>
            {wording.dialogTitle}
          </Text>
        </View>
        {wording.intro ? <Text style={styles.muted}>{wording.intro}</Text> : null}
        {form.types.length > 1 ? (
          <Choice
            label={labels.type}
            options={form.types}
            value={type}
            onChange={(value) => setType(value as ReportType)}
            error={errors.type}
            accent={accent}
            onAccent={onAccent}
            radius={radius}
          />
        ) : null}
        {form.title?.enabled ? (
          <Field
            label={form.title.label}
            value={title}
            onChange={setTitle}
            maxLength={form.title.maxLength ?? 160}
            error={errors.title}
            radius={radius}
          />
        ) : null}
        <Field
          label={form.description?.label ?? 'Description'}
          value={description}
          onChange={setDescription}
          placeholder={form.description?.placeholder}
          maxLength={form.description?.maxLength ?? 10000}
          multiline
          error={errors.description}
          radius={radius}
        />
        {form.fields.map((definition) => (
          <CustomField
            key={definition.key}
            definition={definition}
            value={fields[definition.key] ?? ''}
            onChange={(value) => setFields((current) => ({ ...current, [definition.key]: value }))}
            error={errors[definition.key]}
            accent={accent}
            onAccent={onAccent}
            radius={radius}
          />
        ))}
        {canAttachImages && screenshot ? (
          <View style={styles.field}>
            <Text style={styles.label}>{labels.screenshot}</Text>
            <Image
              source={{ uri: screenshot.uri }}
              style={[styles.preview, { borderRadius: radius / 2 }]}
              resizeMode="contain"
              accessibilityLabel={labels.screenshot}
              accessibilityIgnoresInvertColors
            />
            {button(labels.removeScreenshot, () => setScreenshot(null), false, sending)}
          </View>
        ) : null}
        {canAttachImages && !screenshot && props.onRequestScreenshot
          ? button(labels.addScreenshot, () => void addScreenshot(), false, sending)
          : null}
        {errors.attachments ? <Text style={styles.error}>{errors.attachments}</Text> : null}
        {formError ? (
          <Text accessibilityRole="alert" style={styles.error}>
            {formError}
          </Text>
        ) : null}
        <View style={styles.actions}>
          {button(labels.cancel, onClose, false, sending)}
          {button(sending ? labels.sending : wording.submitLabel, () => void send(), true, sending)}
        </View>
      </ScrollView>
    );
  }

  return (
    <Modal visible={visible} animationType="slide" presentationStyle="pageSheet" onRequestClose={onClose}>
      <KeyboardAvoidingView behavior={Platform.OS === 'ios' ? 'padding' : undefined} style={styles.sheet}>
        {body}
      </KeyboardAvoidingView>
    </Modal>
  );
}

/**
 * Shows the project logo only from an https URL, never from http, data: or file: URLs. A regular
 * expression, because React Native's `URL` does not implement `protocol`.
 */
function isHttpsUrl(value: string | null | undefined): value is string {
  return typeof value === 'string' && /^https:\/\/[^\s/?#\\@]+(?:[/?#]\S*)?$/i.test(value);
}

function pickType(config: Config, preferred: ReportType | undefined): ReportType | null {
  const types = config.form.types;
  return (types.find((option) => option.value === preferred) ?? types[0])?.value ?? null;
}

interface FieldProps {
  label: string;
  value: string;
  onChange: (value: string) => void;
  maxLength: number;
  error: string | undefined;
  radius: number;
  multiline?: boolean;
  placeholder?: string;
}

function Field({ label, value, onChange, maxLength, error, radius, multiline, placeholder }: FieldProps) {
  return (
    <View style={styles.field}>
      <Text style={styles.label}>{label}</Text>
      <TextInput
        accessibilityLabel={label}
        accessibilityHint={error}
        value={value}
        onChangeText={onChange}
        maxLength={maxLength}
        multiline={multiline}
        placeholder={placeholder}
        style={[
          styles.input,
          multiline ? styles.multiline : null,
          { borderRadius: radius / 2 },
          error ? styles.inputError : null,
        ]}
      />
      {error ? <Text style={styles.error}>{error}</Text> : null}
    </View>
  );
}

interface ChoiceProps {
  label: string;
  options: Array<{ value: string; label: string }>;
  value: string | null;
  onChange: (value: string) => void;
  error: string | undefined;
  accent: string;
  onAccent: string;
  radius: number;
}

function Choice({ label, options, value, onChange, error, accent, onAccent, radius }: ChoiceProps) {
  return (
    <View style={styles.field} accessibilityRole="radiogroup" accessibilityLabel={label}>
      <Text style={styles.label}>{label}</Text>
      <View style={styles.chips}>
        {options.map((option) => {
          const selected = option.value === value;
          return (
            <Pressable
              key={option.value}
              accessibilityRole="radio"
              accessibilityState={{ selected }}
              onPress={() => onChange(option.value)}
              style={[
                styles.chip,
                { borderRadius: radius },
                selected ? { backgroundColor: accent, borderColor: accent } : null,
              ]}
            >
              <Text style={selected ? { color: onAccent } : null}>{option.label}</Text>
            </Pressable>
          );
        })}
      </View>
      {error ? <Text style={styles.error}>{error}</Text> : null}
    </View>
  );
}

interface CustomFieldProps {
  definition: FieldDefinition;
  value: string;
  onChange: (value: string) => void;
  error: string | undefined;
  accent: string;
  onAccent: string;
  radius: number;
}

function CustomField({ definition, value, onChange, error, accent, onAccent, radius }: CustomFieldProps) {
  if (definition.type === 'SELECT') {
    return (
      <Choice
        label={definition.label}
        options={(definition.options ?? []).map((option) => ({ value: option, label: option }))}
        value={value || null}
        onChange={onChange}
        error={error}
        accent={accent}
        onAccent={onAccent}
        radius={radius}
      />
    );
  }
  return (
    <Field
      label={definition.label}
      value={value}
      onChange={onChange}
      maxLength={fieldMaxLength(definition)}
      multiline={definition.type === 'LONG_TEXT'}
      error={error}
      radius={radius}
    />
  );
}

const styles = StyleSheet.create({
  sheet: { flex: 1, backgroundColor: '#ffffff' },
  content: { padding: 20, gap: 16 },
  centered: { flex: 1, padding: 24, gap: 16, justifyContent: 'center' },
  header: { flexDirection: 'row', alignItems: 'center', gap: 12 },
  logo: { width: 32, height: 32 },
  title: { fontSize: 20, fontWeight: '700', color: '#1d1d1f' },
  message: { fontSize: 16, color: '#1d1d1f' },
  muted: { color: '#5f6368' },
  field: { gap: 6 },
  label: { fontWeight: '600', color: '#1d1d1f' },
  input: { borderWidth: 1, borderColor: '#c8cbd0', padding: 10, fontSize: 16, color: '#1d1d1f' },
  multiline: { minHeight: 110, textAlignVertical: 'top' },
  inputError: { borderColor: '#b3261e' },
  error: { color: '#b3261e' },
  chips: { flexDirection: 'row', flexWrap: 'wrap', gap: 8 },
  chip: { borderWidth: 1, borderColor: '#c8cbd0', paddingVertical: 8, paddingHorizontal: 12 },
  preview: { width: '100%', height: 200, backgroundColor: '#f1f3f4' },
  actions: { flexDirection: 'row', justifyContent: 'flex-end', gap: 8 },
  button: { borderWidth: 1, borderColor: '#c8cbd0', paddingVertical: 10, paddingHorizontal: 16 },
  buttonText: { fontWeight: '600', color: '#1d1d1f' },
  disabled: { opacity: 0.6 },
});
