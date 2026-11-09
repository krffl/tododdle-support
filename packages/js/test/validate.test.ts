import { describe, expect, it } from 'vitest';
import { fieldMaxLength, validateReport } from '../src/index';
import { cloneConfig, sharedConfig } from './helpers';

const base = { type: 'problem' as const, description: 'x', fields: { area: 'Home' } };

describe('validateReport', () => {
  it('accepts a valid report', () => {
    expect(validateReport(sharedConfig, base)).toEqual({});
  });

  it('checks type, required values, lengths and options', () => {
    const config = cloneConfig();
    if (config.form.title) config.form.title.required = true;
    expect(
      validateReport(config, {
        type: 'question',
        title: '',
        description: ' ',
        fields: { area: 'Moon', steps: 'x'.repeat(5001) },
      }),
    ).toEqual({
      title: 'Enter summary.',
      description: 'Describe what happened.',
      area: 'Choose one of the options.',
      steps: 'Use 5000 characters or fewer.',
    });
    expect(validateReport(config, { ...base, type: 'nope' as 'problem', title: 'x'.repeat(161) })).toEqual({
      type: 'Choose a report type.',
      title: 'Use 160 characters or fewer.',
    });
    expect(validateReport(config, { ...base, title: 'ok', description: 'x'.repeat(10001), fields: {} })).toEqual({
      description: 'Use 10000 characters or fewer.',
      area: 'Choose an option.',
    });
  });

  it('checks required text fields and default lengths', () => {
    const config = cloneConfig();
    config.form.fields = [
      { key: 'short', label: 'Short', type: 'SHORT_TEXT', required: true },
      { key: 'long', label: 'Long', type: 'LONG_TEXT', required: false },
    ];
    expect(fieldMaxLength({ key: 's', label: 's', type: 'SHORT_TEXT', required: false })).toBe(300);
    expect(validateReport(config, { ...base, fields: { long: 'x'.repeat(5001) } })).toEqual({
      short: 'This field is required.',
      long: 'Use 5000 characters or fewer.',
    });
  });

  it('checks attachments', () => {
    const config = cloneConfig();
    const file = (size: number, contentType: 'image/png' | 'text/plain' = 'image/png', fileName = 'a.png') => ({
      fileName,
      contentType,
      data: new Uint8Array(size),
    });
    config.form.attachments = { enabled: true, maxCount: 1, maxBytes: 2048, contentTypes: ['image/png'] };
    expect(validateReport(config, { ...base, attachments: [file(1)] })).toEqual({});
    expect(validateReport(config, { ...base, attachments: [file(1), file(1)] }).attachments).toMatch(/1 files/);
    expect(validateReport(config, { ...base, attachments: [file(1, 'text/plain')] }).attachments).toMatch(/type/);
    expect(validateReport(config, { ...base, attachments: [file(0)] }).attachments).toMatch(/empty/);
    expect(validateReport(config, { ...base, attachments: [file(4096)] }).attachments).toMatch(/over 2 KB/);
    expect(validateReport(config, { ...base, attachments: [file(1, 'image/png', '')] }).attachments).toMatch(/name/);
    config.form.attachments.maxBytes = 10 * 1024 * 1024;
    expect(validateReport(config, { ...base, attachments: [file(11 * 1024 * 1024)] }).attachments).toMatch(/10 MB/);
    config.form.attachments.enabled = false;
    expect(validateReport(config, { ...base, attachments: [file(1)] }).attachments).toMatch(/does not accept/);
  });
});
