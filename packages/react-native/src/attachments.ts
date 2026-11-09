import type { AttachmentContentType, AttachmentInput, FetchLike } from '@krffl/tododdle-support';

/** An image the host app provides, for example from its own screenshot or image picker. */
export interface ImageSource {
  /** A `file://`, `content://`, `data:` or `https://` URI that React Native's `fetch` can read. */
  uri: string;
  fileName?: string;
  contentType?: AttachmentContentType;
}

const typesByExtension: Record<string, AttachmentContentType> = {
  png: 'image/png',
  jpg: 'image/jpeg',
  jpeg: 'image/jpeg',
  webp: 'image/webp',
  gif: 'image/gif',
  pdf: 'application/pdf',
  txt: 'text/plain',
};

const knownTypes = new Set<string>(Object.values(typesByExtension));

function fileNameFrom(uri: string): string {
  const path = uri.split(/[?#]/)[0] ?? '';
  const last = path.split('/').pop() ?? '';
  return last.length > 0 && !uri.startsWith('data:') ? decodeURIComponent(last) : 'screenshot.png';
}

/** Reads an image URI into an attachment. Nothing is read until the person sends the report. */
export async function attachmentFromUri(source: ImageSource, fetchFn: FetchLike = fetch): Promise<AttachmentInput> {
  const response = await fetchFn(source.uri);
  const data = await response.blob();
  const fileName = source.fileName ?? fileNameFrom(source.uri);
  const extension = fileName.split('.').pop()?.toLowerCase() ?? '';
  const blobType = data.type.split(';')[0] ?? '';
  const contentType: AttachmentContentType =
    source.contentType ??
    (knownTypes.has(blobType) ? (blobType as AttachmentContentType) : undefined) ??
    typesByExtension[extension] ??
    'image/png';
  return { fileName, contentType, data };
}
