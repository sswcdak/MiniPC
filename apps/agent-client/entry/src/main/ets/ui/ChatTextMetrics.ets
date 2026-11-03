/** Visible text characters, including punctuation and emoji; whitespace is excluded. */
export function chatCharacterCount(text: string): number {
  let count = 0;
  for (let index = 0; index < text.length; index++) {
    if (/\s/.test(text.charAt(index))) continue;
    const code = text.charCodeAt(index);
    if (code >= 0xD800 && code <= 0xDBFF && index + 1 < text.length) {
      const next = text.charCodeAt(index + 1);
      if (next >= 0xDC00 && next <= 0xDFFF) index++;
    }
    count++;
  }
  return count;
}

export function chatCharacterLabel(text: string): string {
  return chatCharacterCount(text) + '字';
}
