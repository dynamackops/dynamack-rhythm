import test from 'node:test';
import assert from 'node:assert/strict';
import { normalizeReceiptItems } from './receipt-items.mjs';

test('normalizes receipt items, removes duplicate names and defaults unknown categories', () => {
  assert.deepEqual(normalizeReceiptItems([
    { name: '  Crème  Bread ', category: 'grain' },
    { name: 'crème bread', category: 'grain' },
    { name: 'Tea', category: 'untrusted' },
    { name: '<script>', category: 'other' },
    null,
  ]), [
    { item_key: 'creme-bread', name: 'Crème Bread', category: 'grain', stock_status: 'available', quantity_estimate: null, unit: null },
    { item_key: 'tea', name: 'Tea', category: 'other', stock_status: 'available', quantity_estimate: null, unit: null },
    { item_key: 'script', name: '<script>', category: 'other', stock_status: 'available', quantity_estimate: null, unit: null },
  ]);
});
