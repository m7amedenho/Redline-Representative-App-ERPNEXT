# مرجع Endpoints (مستخرج من ملفات OpenAPI)

مستخرج آليًا مرة واحدة من `erpnext-app-openapi (1).json` و`frappe-app-openapi (1).json` — استخدم هذا الملف بدل فتح الملفين الكبيرين. لو احتجت endpoint جديد، استخدم grep على اسم الدالة بدل تحميل الملف كامل.


## من erpnext-app-openapi (1).json

### `GET /api/method/erpnext.accounts.party.get_party_details`
- operationId: `erpnext_accounts_party_get_party_details`
- Parameters:
  - `party` (query, optional, string)
  - `account` (query, optional, string)
  - `party_type` (query, optional, string)
  - `company` (query, optional, string)
  - `posting_date` (query, optional, string)
  - `bill_date` (query, optional, string)
  - `price_list` (query, optional, string)
  - `currency` (query, optional, string)
  - `doctype` (query, optional, string)
  - `ignore_permissions` (query, optional, string)
  - `fetch_payment_terms_template` (query, optional, string)
  - `party_address` (query, optional, string)
  - `company_address` (query, optional, string)
  - `shipping_address` (query, optional, string)
  - `dispatch_address` (query, optional, string)
  - `pos_profile` (query, optional, string)

### `GET /api/method/erpnext.selling.doctype.sales_order.sales_order.make_sales_invoice`
- operationId: `erpnext_selling_doctype_sales_order_sales_order_make_sales_invoice`
- Parameters:
  - `source_name` (query, required, string)
  - `target_doc` (query, optional, string)
  - `ignore_permissions` (query, optional, string)
  - `args` (query, optional, string)

### `GET /api/method/erpnext.accounts.doctype.sales_invoice.sales_invoice.make_sales_return`
- operationId: `erpnext_accounts_doctype_sales_invoice_sales_invoice_make_sales_return`
- Parameters:
  - `source_name` (query, required, string)
  - `target_doc` (query, optional, string)

### `GET /api/method/erpnext.selling.doctype.customer.customer.make_payment_entry`
- operationId: `erpnext_selling_doctype_customer_customer_make_payment_entry`
- Parameters:
  - `source_name` (query, required, string)
  - `target_doc` (query, optional, string)

### `GET /api/method/erpnext.accounts.doctype.payment_entry.payment_entry.get_outstanding_reference_documents`
- operationId: `erpnext_accounts_doctype_payment_entry_payment_entry_get_outstanding_reference_documents`
- Parameters:
  - `args` (query, required, string)
  - `validate` (query, optional, string)

### `GET /api/method/erpnext.stock.doctype.material_request.material_request.make_in_transit_stock_entry`
- operationId: `erpnext_stock_doctype_material_request_material_request_make_in_transit_stock_entry`
- Parameters:
  - `source_name` (query, required, string)
  - `in_transit_warehouse` (query, required, string)

### `GET /api/method/erpnext.stock.doctype.material_request.material_request.make_stock_entry`
- operationId: `erpnext_stock_doctype_material_request_material_request_make_stock_entry`
- Parameters:
  - `source_name` (query, required, string)
  - `target_doc` (query, optional, string)

### `GET /api/method/erpnext.stock.doctype.warehouse.warehouse.get_children`
- operationId: `erpnext_stock_doctype_warehouse_warehouse_get_children`
- Parameters:
  - `doctype` (query, required, string)
  - `parent` (query, optional, string)
  - `company` (query, optional, string)
  - `is_root` (query, optional, string)
  - `include_disabled` (query, optional, string)

## من frappe-app-openapi (1).json
