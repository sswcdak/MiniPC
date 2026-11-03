import { fileIo, picker } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import fs from '@ohos.file.fs';
import { ensureSandboxWorkspace, sandboxWorkspacePath } from '@loop/agent-core';

const EXCERPT_CHARS = 1600;

export interface SavedAttachment {
  kind: string;
  name: string;
  relativePath: string;
  localPath: string;
}

/** Install the bundled example in the same workspace used by picked images and inference. */
export async function prepareQuickInputCat(context: common.Context): Promise<SavedAttachment> {
  const bytes = await context.resourceManager.getRawFileContent('quick-inputs/cat.jpg');
  if (bytes.byteLength === 0) throw new Error('猫图素材为空');
  ensureSandboxWorkspace();
  const folder = sandboxWorkspacePath('uploads');
  if (!pathExists(folder)) fs.mkdirSync(folder, true);
  const relativePath = 'uploads/quick-input-cat-v1.jpg';
  const localPath = sandboxWorkspacePath(relativePath);
  const file = fs.openSync(localPath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
  try {
    const data = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
    if (fs.writeSync(file.fd, data) !== bytes.byteLength) throw new Error('猫图保存不完整');
  } finally { fs.closeSync(file); }
  return { kind: 'image', name: 'cat.jpg', relativePath: relativePath, localPath: localPath };
}

export function pickAttachment(): Promise<SavedAttachment | null> {
  const view = new picker.DocumentViewPicker();
  const options = new picker.DocumentSelectOptions();
  options.maxSelectNumber = 1;
  return view.select(options).then((uris: Array<string>): SavedAttachment | null => {
    if (uris.length === 0) {
      return null;
    }
    const name = nameFromUri(uris[0]);
    const kind = isImageName(name) ? 'image' : 'document';
    return saveUri(kind, uris[0], kind === 'image' ? imageName(name) : name);
  }).catch((error: BusinessError): SavedAttachment | null => {
    if (isCancel(error)) {
      return null;
    }
    throw new Error(error.message || '附件选择失败');
  });
}

export function readTextExcerpt(relativePath: string): string {
  const lower = relativePath.toLowerCase();
  if (!lower.endsWith('.txt') && !lower.endsWith('.md') && !lower.endsWith('.json') && !lower.endsWith('.csv')) {
    return '';
  }
  try {
    const absolute = sandboxWorkspacePath(relativePath);
    const stat = fs.statSync(absolute);
    if (stat.size > 64 * 1024) {
      return '';
    }
    const text = fs.readTextSync(absolute, { encoding: 'utf-8' }).trim();
    const chars = Array.from(text);
    if (chars.length <= EXCERPT_CHARS) {
      return text;
    }
    return chars.slice(0, EXCERPT_CHARS).join('') + '\n…（附件已截断，完整文件在工作区）';
  } catch (_error) {
    return '';
  }
}

function saveUri(kind: string, uri: string, name: string): SavedAttachment {
  ensureSandboxWorkspace();
  const folder = sandboxWorkspacePath('uploads');
  if (!pathExists(folder)) {
    fs.mkdirSync(folder, true);
  }
  const relativePath = `uploads/${Date.now()}-${safeName(name)}`;
  const localPath = sandboxWorkspacePath(relativePath);
  const src = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
  try {
    const out = fileIo.openSync(localPath,
      fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
    try {
      fileIo.copyFileSync(src.fd, out.fd);
    } finally {
      fileIo.closeSync(out);
    }
  } finally {
    fileIo.closeSync(src);
  }
  return { kind: kind, name: name, relativePath: relativePath, localPath: localPath };
}

function isImageName(name: string): boolean {
  const lower = name.toLowerCase();
  return lower.endsWith('.jpg') || lower.endsWith('.jpeg') || lower.endsWith('.png') ||
    lower.endsWith('.webp') || lower.endsWith('.gif') || lower.endsWith('.bmp') || lower.endsWith('.heic');
}

function imageName(name: string): string {
  const lower = name.toLowerCase();
  if (lower.endsWith('.jpg') || lower.endsWith('.jpeg') || lower.endsWith('.png') || lower.endsWith('.webp')) {
    return name;
  }
  return `${name}.jpg`;
}

function nameFromUri(uri: string): string {
  const query = uri.indexOf('?');
  const clean = query >= 0 ? uri.substring(0, query) : uri;
  const slash = Math.max(clean.lastIndexOf('/'), clean.lastIndexOf('\\'));
  const raw = slash >= 0 ? clean.substring(slash + 1) : clean;
  if (raw.length === 0) {
    return 'file';
  }
  try {
    return decodeURIComponent(raw);
  } catch (_error) {
    return raw;
  }
}

function safeName(raw: string): string {
  let out = '';
  for (let i = 0; i < raw.length && out.length < 60; i++) {
    const code = raw.charCodeAt(i);
    const ok = (code >= 48 && code <= 57) || (code >= 65 && code <= 90) || (code >= 97 && code <= 122) ||
      code === 46 || code === 45 || code === 95 || code > 127;
    out += ok ? raw.charAt(i) : '_';
  }
  if (out.length === 0 || out === '.' || out === '..') {
    return 'file';
  }
  return out;
}

function pathExists(path: string): boolean {
  try {
    return fs.accessSync(path);
  } catch (_error) {
    return false;
  }
}

function isCancel(error: BusinessError): boolean {
  if (error.code === 13900020 || error.code === 13900002 || error.code === 801) {
    return true;
  }
  const msg = error.message ? error.message.toLowerCase() : '';
  return msg.indexOf('cancel') >= 0;
}
