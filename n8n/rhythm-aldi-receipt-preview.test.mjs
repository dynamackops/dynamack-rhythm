import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const code = await readFile(new URL('./rhythm-aldi-receipt-preview.js', import.meta.url), 'utf8');
const run = (messages) => new Function('$input', code)({ all: () => messages.map(json => ({ json })) });
const directHtml = `<html><body><h2>Items Found</h2><table>
<tr><td><img src="item.png"></td><td><div>2 x Apple</div><div>Red Delicious</div></td><td><strong>2</strong></td></tr>
<tr><td><img src="item.png"></td><td><div>1 x Chicken Breast</div><div>Fresh</div></td><td><strong>1</strong></td></tr>
<tr><td><img src="item.png"></td><td><div>1 x Apple</div><div>Red Delicious</div></td><td><strong>1</strong></td></tr>
<h2>Order Totals</h2><tr><td><img src="promo.png"></td><td><div>Not a grocery item</div></td></tr>
</table></body></html>`;
const instacartHtml = `<html><body><h2>Items found (ALDI)</h2>
<div class="item-name">Pasta</div><div class="item-name">Olive Oil</div></body></html>`;
const direct = (date, html=directHtml) => ({ id: 'aldi-' + date, From: 'ALDI <orders@shop.aldi.us>', Subject: 'ALDI order receipt', internalDate: String(Date.parse(date)), html });
const instacart = (date, html=instacartHtml) => ({ id: 'instacart-' + date, From: 'Instacart <orders@instacart.com>', Subject: 'Your Instacart order receipt', internalDate: String(Date.parse(date)), html });

test('prefers the latest direct ALDI receipt and deduplicates item names', () => {
  const [result] = run([instacart('2026-10-17'), direct('2026-10-11')]);
  assert.equal(result.json.source, 'aldi_email');
  assert.equal(result.json.purchasedOn, '2026-10-11');
  assert.deepEqual(result.json.items.map(x => x.name), ['Apple', 'Chicken Breast']);
  assert.equal(result.json.items[0].category, 'fruit');
});
test('falls back to the latest Instacart Aldi receipt when no direct ALDI email exists', () => {
  const [result] = run([instacart('2026-10-10'), instacart('2026-10-17')]);
  assert.equal(result.json.source, 'instacart_aldi');
  assert.equal(result.json.purchasedOn, '2026-10-17');
  assert.deepEqual(result.json.items.map(x => x.name), ['Pasta', 'Olive Oil']);
});

