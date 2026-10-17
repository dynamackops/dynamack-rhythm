const RECEIPT_CATEGORIES = new Set(['protein','vegetable','fruit','breakfast','grain','drink','dessert','snack','other']);
export function normalizeReceiptItems(items) {
  if (!Array.isArray(items)) return [];
  const seen = new Set();
  return items.flatMap((item) => {
    const name = String(item?.name || '').trim().replace(/\s+/g, ' ').slice(0, 120);
    const key = name.normalize('NFKD').replace(/[\u0300-\u036f]/g, '').toLowerCase()
      .replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 100);
    if (!name || !key || seen.has(key)) return [];
    seen.add(key);
    const category = RECEIPT_CATEGORIES.has(item?.category) ? item.category : 'other';
    return [{ item_key: key, name, category, stock_status: 'available', quantity_estimate: null, unit: null }];
  });
}
