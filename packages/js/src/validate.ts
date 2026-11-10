import type { Config, FieldDefinition, ReportInput } from './types';
import { byteSize } from './util';

export const TITLE_MAX_LENGTH = 160;
export const DESCRIPTION_MAX_LENGTH = 10000;
const SHORT_TEXT_MAX_LENGTH = 300;
const LONG_TEXT_MAX_LENGTH = 5000;

/** The longest value a field accepts. */
export function fieldMaxLength(field: FieldDefinition): number {
  if (field.maxLength !== undefined) return field.maxLength;
  return field.type === 'LONG_TEXT' ? LONG_TEXT_MAX_LENGTH : SHORT_TEXT_MAX_LENGTH;
}

function isBlank(value: string | undefined): boolean {
  return value === undefined || value.trim().length === 0;
}

function formatBytes(bytes: number): string {
  return bytes >= 1024 * 1024 ? `${Math.round(bytes / (1024 * 1024))} MB` : `${Math.round(bytes / 1024)} KB`;
}

/**
 * Checks a report against the config the way the server will: report type, required values,
 * maximum lengths, SELECT options and attachment rules. Returns a message per key: `type`,
 * `title`, `description`, `attachments` or a custom field key. An empty object means valid.
 */
export function validateReport(config: Config, input: ReportInput): Record<string, string> {
  const errors: Record<string, string> = {};
  const { form } = config;

  if (!form.types.some((option) => option.value === input.type)) {
    errors.type = 'Choose a report type.';
  }

  const title = form.title;
  if (title?.enabled) {
    if (title.required && isBlank(input.title)) errors.title = 'This field is required.';
    const max = title.maxLength ?? TITLE_MAX_LENGTH;
    if (input.title !== undefined && input.title.length > max) errors.title = `Use ${max} characters or fewer.`;
  }

  const description = form.description;
  const descriptionMax = description?.maxLength ?? DESCRIPTION_MAX_LENGTH;
  if (description?.required && isBlank(input.description)) errors.description = 'This field is required.';
  if (input.description !== undefined && input.description.length > descriptionMax) {
    errors.description = `Use ${descriptionMax} characters or fewer.`;
  }

  const values = input.fields ?? {};
  for (const field of form.fields) {
    const value = values[field.key];
    if (field.required && isBlank(value)) {
      errors[field.key] = field.type === 'SELECT' ? 'Choose an option.' : 'This field is required.';
      continue;
    }
    if (value === undefined || value.length === 0) continue;
    if (field.type === 'SELECT' && !(field.options ?? []).includes(value)) {
      errors[field.key] = 'Choose one of the options.';
      continue;
    }
    const max = fieldMaxLength(field);
    if (value.length > max) errors[field.key] = `Use ${max} characters or fewer.`;
  }

  const attachments = input.attachments ?? [];
  if (attachments.length > 0) {
    const rules = form.attachments;
    const allowedTypes: readonly string[] = rules.contentTypes;
    if (!rules.enabled) {
      errors.attachments = 'This form does not accept attachments.';
    } else if (attachments.length > rules.maxCount) {
      errors.attachments = `Attach ${rules.maxCount} files or fewer.`;
    } else {
      for (const attachment of attachments) {
        const size = byteSize(attachment.data);
        if (!allowedTypes.includes(attachment.contentType)) {
          errors.attachments = `${attachment.fileName}: this file type is not allowed.`;
        } else if (size === 0) {
          errors.attachments = `${attachment.fileName} is empty.`;
        } else if (size > rules.maxBytes) {
          errors.attachments = `${attachment.fileName} is over ${formatBytes(rules.maxBytes)}.`;
        } else if (attachment.fileName.length === 0 || attachment.fileName.length > 255) {
          errors.attachments = 'Each file needs a name of 255 characters or fewer.';
        }
        if (errors.attachments) break;
      }
    }
  }

  return errors;
}
