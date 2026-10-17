function decodeHtml(value) {
  return String(value || '').replace(/&nbsp;/gi, ' ').replace(/&amp;/gi, '&')
    .replace(/&quot;/gi, '"').replace(/&#39;|&apos;/gi, "'")
    .replace(/&lt;/gi, '<').replace(/&gt;/gi, ' ')
    .replace(/&#(\d+);/g, (_, code) => String.fromCharCode(Number(code)))
    .replace(/&#x([0-9a-f]+);/gi, (_, code) => String.fromCharCode(parseInt(code, 16)));
}
function plainText(html) {
  return decodeHtml(String(html || '').replace(/<style[\s\S]*?<\/style>|<script[\s\S]*?<\/script>/gi, ' ')
    .replace(/<br\s*\/?\s*>/gi, '\n')
    .replace(/<\/(?:p|div|tr|td|h[1-6]|li)\s*>/gi, '\n')
    .replace(/<[^>]*>/g, ' ')).replace(/[ \t]+/g, ' ')
    .split('\n').map(line => line.trim()).filter(Boolean).join('\n');
}
function header(message, key) {
  const direct = message[key] || message[key.toLowerCase()];
  if (direct) return String(direct);
  const headers = message.payload?.headers || message.headers || [];
  const item = headers.find(h => String(h.name || '').toLowerCase() === key.toLowerCase());
  return String(item?.value || '');
}
function decodeBodyData(value) {
  if (typeof value !== 'string' || !value) return '';
  // Gmail API encodes MIME bodies as base64url in payload.body.data.
  try {
    const normalized = value.replace(/-/g, '+').replace(/_/g, '/');
    return Buffer.from(normalized, 'base64').toString('utf8');
  } catch {
    return '';
  }
}
function htmlBody(message) {
  for (const candidate of [message.html, message.textAsHtml, message.textHtml, message.body?.html,
    message.payload?.body?.content, decodeBodyData(message.payload?.body?.data),
    decodeBodyData(message.payload?.body?.base64_url_content)]) {
    if (typeof candidate === 'string' && /<html|<table|<div/i.test(candidate)) return candidate;
  }
  function findHtml(part) {
    if (!part) return '';
    if (/text\/html/i.test(part.mimeType || part.mime_type || '')) {
      const body = part.body?.content || decodeBodyData(part.body?.data) || decodeBodyData(part.body?.base64_url_content);
      if (typeof body === 'string' && body) return body;
    }
    for (const child of part.parts || []) {
      const found = findHtml(child);
      if (found) return found;
    }
    return '';
  }
  return findHtml(message.payload);
}
function categoryFor(name) {
  const n = name.toLowerCase();
  if (/(chicken|beef|pork|turkey|fish|salmon|shrimp|tofu|egg|sausage|bacon|ham|tuna)/.test(n)) return 'protein';
  if (/(broccoli|spinach|lettuce|pepper|onion|tomato|potato|carrot|corn|cucumber|vegetable|salad|celery|mushroom)/.test(n)) return 'vegetable';
  if (/(apple|banana|berry|berries|orange|grape|melon|peach|pear|lemon|lime|fruit|mango|pineapple)/.test(n)) return 'fruit';
  if (/(milk|yogurt|oatmeal|cereal|pancake|waffle|breakfast)/.test(n)) return 'breakfast';
  if (/(rice|pasta|noodle|bread|tortilla|quinoa|grain|flour|cracker)/.test(n)) return 'grain';
  if (/(water|juice|soda|coffee|tea|drink|beverage)/.test(n)) return 'drink';
  if (/(cookie|cake|ice cream|chocolate|dessert|candy)/.test(n)) return 'dessert';
  if (/(chip|snack|pretzel|popcorn|bar)/.test(n)) return 'snack';
  return 'other';
}
function safeItems(names) {
  const seen = new Set();
  return names.flatMap(raw => {
    const name = String(raw || '').trim().replace(/^\d+\s*x\s*/i, '').replace(/\s+/g, ' ').slice(0, 120);
    const itemKey = name.toLowerCase().normalize('NFKD').replace(/[\u0300-\u036f]/g, '')
      .replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 100);
    if (!name || !itemKey || seen.has(itemKey)) return [];
    seen.add(itemKey);
    return [{ item_key: itemKey, name, category: categoryFor(name), stock_status: 'available', quantity_estimate: null, unit: null }];
  });
}
function messageDate(message) {
  const raw = message.internalDate || message.internal_date || message.email_ts || message.date || '';
  const time = Number(raw);
  const date = time ? new Date(time > 1000000000000 ? time : time * 1000) : new Date(raw);
  return Number.isNaN(date.getTime()) ? null : date.toISOString().slice(0, 10);
}
function baseReceipt(message, source, items) {
  const rawTime = Number(message.internalDate || message.internal_date || 0);
  const timestamp = rawTime ? (rawTime > 1000000000000 ? rawTime : rawTime * 1000) : Date.parse(message.email_ts || message.date || '') || 0;
  return { ok: true, source, messageId: String(message.id || message.messageId || ''), purchasedOn: messageDate(message), store: 'ALDI', items, _timestamp: timestamp };
}
function parseAldiEmail(message) {
  const sender = header(message, 'From');
  const subject = header(message, 'Subject');
  if (!/@(?:shop\.aldi\.us|aldi\.us)\b/i.test(sender) || !/aldi.{0,20}receipt|receipt.{0,20}aldi/i.test(subject)) return null;
  const html = htmlBody(message);
  const marker = html.search(/Items\s+Found/i);
  if (marker < 0) return null;
  let region = html.slice(marker);
  const end = region.search(/Order\s+Totals/i);
  if (end > 0) region = region.slice(0, end);
  const names = [];
  for (const match of region.matchAll(/<tr\b[^>]*>([\s\S]*?)<\/tr>/gi)) {
    const row = match[1];
    const imageIndex = row.search(/<img\b/i);
    if (imageIndex < 0) continue;
    const imageCellEnd = row.indexOf('</td>', imageIndex);
    const nameCellStart = row.indexOf('<td', imageCellEnd);
    const nameCellEnd = row.indexOf('</td>', nameCellStart);
    if (imageCellEnd < 0 || nameCellStart < 0 || nameCellEnd < 0) continue;
    const cell = row.slice(nameCellStart, nameCellEnd);
    const nameMatch = cell.match(/<div\b[^>]*>([\s\S]*?)<\/div>/i);
    if (!nameMatch) continue;
    const name = plainText(nameMatch[1]).replace(/\s+/g, ' ').trim();
    if (name) names.push(name);
  }
  const items = safeItems(names);
  return items.length ? baseReceipt(message, 'aldi_email', items) : null;
}
function parseInstacartReceipt(message) {
  const sender = header(message, 'From');
  const subject = header(message, 'Subject');
  if (!/instacart/i.test(sender) || !/instacart order receipt/i.test(subject)) return null;
  const html = htmlBody(message);
  if (!/\bitems\s+found\s*\(\s*aldi\s*\)/i.test(plainText(html))) return null;
  const names = [...html.matchAll(/<div[^>]*class=["'][^"']*\bitem-name\b[^"']*["'][^>]*>([\s\S]*?)<\/div>/gi)]
    .map(match => plainText(match[1]).split('\n')[0].trim().replace(/\s+/g, ' '));
  const items = safeItems(names);
  return items.length ? baseReceipt(message, 'instacart_aldi', items) : null;
}
const messages = $input.all().map(item => item.json)
  .sort((a, b) => Number(b.internalDate || b.internal_date || 0) - Number(a.internalDate || a.internal_date || 0));
const aldiReceipts = messages.map(message => parseAldiEmail(message)).filter(Boolean)
  .sort((a, b) => b._timestamp - a._timestamp);
const instacartReceipts = messages.map(message => parseInstacartReceipt(message)).filter(Boolean)
  .sort((a, b) => b._timestamp - a._timestamp);
const receipt = aldiReceipts[0] || instacartReceipts[0];
if (!receipt) return [{ json: { ok: false, message: 'No recent ALDI receipt was found.' } }];
delete receipt._timestamp;
return [{ json: receipt }];

