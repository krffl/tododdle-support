import { describe, expect, it } from 'vitest';
import { isAllowedUrl, isHexColor, isHttpsUrl, safeUploadHeaders, stripQuery } from '../src/util';

describe('isAllowedUrl', () => {
  it('allows https anywhere and http only on loopback hosts', () => {
    for (const good of [
      'https://app.tododdle.com/api',
      'https://files.example:8443/a?b#c',
      'http://127.0.0.1',
      'http://localhost:8080/x',
      'http://LOCALHOST',
      'http://[::1]:3000/',
      'http://user:pass@127.0.0.1/',
    ]) {
      expect(isAllowedUrl(good), good).toBe(true);
    }
    for (const bad of [
      'http://example.test',
      'http://127.0.0.2',
      'http://localhost.example.test',
      'http://127.0.0.1@evil.example',
      'http://evil.example\\@localhost',
      'http://evil.example\\localhost',
      'http://[::2]',
      'ws://localhost',
      'file:///tmp/x',
      'data:text/plain,x',
      'https://',
      'https:/example.test',
      'https://exa\nmple.test',
      '',
    ]) {
      expect(isAllowedUrl(bad), bad).toBe(false);
    }
  });
});

describe('isHttpsUrl', () => {
  it('accepts only https URLs', () => {
    expect(isHttpsUrl('https://example.test/logo.png')).toBe(true);
    expect(isHttpsUrl('http://example.test/logo.png')).toBe(false);
    expect(isHttpsUrl('http://localhost/logo.png')).toBe(false);
    expect(isHttpsUrl('data:image/png;base64,AAAA')).toBe(false);
    expect(isHttpsUrl('javascript:alert(1)')).toBe(false);
    expect(isHttpsUrl(null)).toBe(false);
    expect(isHttpsUrl(undefined)).toBe(false);
  });
});

describe('isHexColor', () => {
  it('matches the contract HexColor pattern', () => {
    expect(isHexColor('#2f6d4f')).toBe(true);
    for (const bad of ['#2F6D4F', '#fff', 'red', '#2f6d4f;background:url(x)', 'var(--x)', '', null, 7]) {
      expect(isHexColor(bad), String(bad)).toBe(false);
    }
  });
});

describe('safeUploadHeaders', () => {
  it('drops forbidden headers in any case and keeps the rest', () => {
    expect(
      safeUploadHeaders({
        'Content-Type': 'image/png',
        'x-goog-meta': 'a',
        host: 'h',
        Authorization: 'a',
        Cookie: 'c',
        'proxy-authorization': 'p',
        'Proxy-Connection': 'p',
        connection: 'close',
        'TRANSFER-ENCODING': 'chunked',
        'Content-Length': '1',
      }),
    ).toEqual({ 'Content-Type': 'image/png', 'x-goog-meta': 'a' });
    expect(safeUploadHeaders(undefined)).toEqual({});
  });
});

describe('stripQuery', () => {
  it('drops the query string and fragment', () => {
    expect(stripQuery('/a/b?token=1#x')).toBe('/a/b');
    expect(stripQuery('Favourites#token=abc')).toBe('Favourites');
    expect(stripQuery('Home')).toBe('Home');
  });
});
