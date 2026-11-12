import { describe, expect, it } from 'vitest';
import { attachmentFromUri, createTododdleSupport, platformContext, SDK_VERSION } from '../src/index';

describe('platformContext', () => {
  it('adds only the OS and what the host passes', () => {
    expect(platformContext()).toEqual({ platform: 'react-native', osName: 'ios', osVersion: '18.2' });
    expect(platformContext({ appVersion: '2.4.0', build: '118' })).toEqual({
      platform: 'react-native',
      osName: 'ios',
      osVersion: '18.2',
      appVersion: '2.4.0',
      build: '118',
    });
  });
});

describe('createTododdleSupport (React Native)', () => {
  it('sends the react-native SDK header and platform context', async () => {
    const calls: Array<{ url: string; init: RequestInit | undefined }> = [];
    const fetch = async (url: string, init?: RequestInit) => {
      calls.push({ url, init });
      return new Response(JSON.stringify({ reportId: 'rpt_AAAAAAAAAAAAAAAA0001', status: 'received' }), {
        status: 201,
      });
    };
    const client = createTododdleSupport({
      key: 'tdsk_pub_TESTKEY0000000000000000000000000',
      baseUrl: 'https://example.test',
      fetch,
      appId: 'com.example',
      appVersion: '2.4.0',
      defaultContext: { screen: 'Home' },
    });
    await client.report({ type: 'problem', formVersion: 3 }, { skipValidation: true });
    const headers = new Headers(calls[0]?.init?.headers);
    expect(headers.get('X-Tododdle-Sdk')).toBe(`react-native/${SDK_VERSION}`);
    expect(headers.get('X-Tododdle-App-Id')).toBe('com.example');
    expect(JSON.parse(String(calls[0]?.init?.body)).context).toEqual({
      platform: 'react-native',
      osName: 'ios',
      osVersion: '18.2',
      appVersion: '2.4.0',
      screen: 'Home',
    });
  });
});

describe('attachmentFromUri', () => {
  const fetchBlob = (type: string) => async () => new Response(new Blob([new Uint8Array([1, 2])], { type }));

  it('reads the URI and works out the name and type', async () => {
    const fromBlob = await attachmentFromUri({ uri: 'file:///tmp/My%20Shot.jpg' }, fetchBlob('image/webp'));
    expect(fromBlob).toMatchObject({ fileName: 'My Shot.jpg', contentType: 'image/webp' });
    expect((fromBlob.data as Blob).size).toBe(2);
    const fromExtension = await attachmentFromUri({ uri: 'file:///tmp/a.JPEG?x=1' }, fetchBlob(''));
    expect(fromExtension).toMatchObject({ fileName: 'a.JPEG', contentType: 'image/jpeg' });
    const fromData = await attachmentFromUri({ uri: 'data:image/png;base64,AA==' }, fetchBlob('application/x'));
    expect(fromData).toMatchObject({ fileName: 'screenshot.png', contentType: 'image/png' });
    const given = await attachmentFromUri(
      { uri: 'content://x/1', fileName: 'shot.gif', contentType: 'image/gif' },
      fetchBlob('image/png'),
    );
    expect(given).toMatchObject({ fileName: 'shot.gif', contentType: 'image/gif' });
  });
});
