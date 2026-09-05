# الحالة الحالية — Red ERP (ملخص كثيف، بدون الحاجة لقراءة أي محادثة سابقة)

آخر تحديث: بعد جولة "حدود الخصم حسب الدور لكل صنف" — أول جولة فيها وصول مباشر حقيقي للسيرفر عبر API Key. للتفاصيل والافتراضات الكاملة لكل جولة، راجع `docs/API_INTEGRATION_NOTES.md` (تاريخي، تراكمي). الملف ده بديل سريع بس.

**Backend**: ERPNext/Frappe على `app.alexasfor.com` + تطبيق مخصص `mobile_control` (auth) + تطبيق مخصص `red_app` (Module: "Red App" — Treasury، Item Discount Limit، وغيره). المصادقة: بصمة اختيارية + توكن مخزّن، مفيش أي دخول صامت للـ Home أبدًا (قرار أمني مقصود).

**🔑 وصول API مباشر متاح**: عندي API Key/Secret حقيقي (Administrator) على السيرفر ده — بستخدمه للفحص/التحقق المباشر (قراءة أساسًا)، مش للتعديل إلا بإذن صريح لكل مرة.

---

## 1) الشاشات وحالتها

| الشاشة | الحالة | ملاحظة |
|---|---|---|
| `splash_screen.dart` | ✅ شغالة | تحدد بس فيه جلسة محفوظة ولا لأ، توجّه لـ `/auth` أو `/onboarding` — بدون أي محاولة دخول تلقائي |
| `onboarding_screen.dart` | ✅ شغالة | بدون تغيير |
| `auth_screen.dart` | ✅ شغالة، محتاجة اختبار حقيقي للبصمة | زرار بصمة صريح (مش تلقائي) يظهر بس لو فيه جلسة محفوظة + الخاصية شغالة + الجهاز بيدعم. الدومين بيتملى تلقائيًا من آخر مرة. الفورم اليدوي دايمًا متاح |
| `welcome_screen.dart` | 🆕 جديدة، محتاجة اختبار | شاشة عبور "مرحبًا، [الاسم]" بعد أي دخول ناجح، بتنتقل تلقائيًا لـ Home بعد ~1.4 ثانية |
| `home_screen.dart` | ✅ شغالة | شبكة إجراءات سريعة **مسطّحة** (3 أيقونات بالصف، بدون فئات — رجّعناها كده بعد ما المستخدم رفض التقسيم لفئات)، كاروسيل خزائن حقيقي، آخر نشاطات حقيقية، ترحيب بدون سطر "مندوب مبيعات" الثابت |
| `account_screen.dart` | ✅ شغالة | تسجيل خروج + مفتاح تفعيل البصمة |
| `notifications_screen.dart` | ✅ شغالة | `Notification Log` |
| `sales_order_screen.dart` | ⚠️ محتاجة اختبار حقيقي | تاب "طلبية جديدة" + تاب "كل الطلبيات" (جديد). حفظ كمسودة، فلتر عملاء المندوب + ترس فلترة بخط السير (لو أكتر من territory) + منطقة العميل تحت الاسم، سقف الدين + المديونية الحالية، قائمة أسعار يدوية، عداد كمية، مخزن اختياري لكل صنف، GPS **إجباري** (يمنع الإرسال لحد ما ينجح)، Sales Person تلقائي |
| `sales_invoice_screen.dart` | ⚠️ محتاجة اختبار | نفس تعديلات الطلبية على تاب "إصدار مباشر" فقط. تابا "تحويل من طلبية"/"مرتجع" بدون تغيير |
| `payment_entry_screen.dart` | ⚠️ محتاجة اختبار | فلتر عملاء المندوب + منطقة العميل، `tryAutoProgress` اتشالت |
| `material_request_screen.dart` | ⚠️ محتاجة اختبار | تابين (طلب مواد / استلام) — `tryAutoProgress` اتشالت من الاتنين. تاب "استلام" **لسه بيستخدم الآلية القديمة** (`make_in_transit_stock_entry`) — استبدالها بـ Workflow حقيقي **مؤجَّل**، السيرفر لسه مش جاهز له |
| `expenses_screen.dart` | ⚠️ محتاجة اختبار | Wizard: نوع (سيارة/شخصي) → فرعي (وقود/صيانة/أخرى) → فورم. `tryAutoProgress` اتشالت من مسارين (Vehicle Log و Expense Claim) |
| `customers_screen.dart` | ⚠️ محتاجة اختبار | مفتاح "عملائي فقط" (**افتراضي مقفول** — بيثق في صلاحيات السيرفر، تفعيله يضيف فلتر `account_manager` اختياري)، منطقة العميل تحت الاسم، "كشف حساب" في bottom sheet |
| `customer_statement_screen.dart` | 🆕 محتاجة اختبار | كشف حساب عبر `GL Entry` — حقول غير مؤكدة، محتاجة الـ Role "Accounts User" أو مكافئها |
| `customer_registration_screen.dart` | 🆕 محتاجة اختبار | كل الحقول مؤكدة من ERD حقيقي. `account_manager`/`disabled=1` تلقائيًا |
| `treasury_screen.dart` | ✅ شغالة (مختبرة قبل كده) | `Treasury` DocType |
| `document_detail_screen.dart` | ⚠️ **الأهم، محتاجة اختبار** | حالة + Workflow stepper + "اسحب للإرسال" + قسم أصناف + قسم إجماليات + زرار "تعديل الخصم" (خصم المستند الكلي) + زرار منشن + **جديد**: أيقونة تعديل خصم لكل صنف على حدة، بحد أقصى حسب دور المستخدم (`Item.custom_role_discount_limits`) |
| `pending_approvals_screen.dart` | 🆕 محتاجة اختبار | "بانتظار موافقتي" — اختيار Doctype ثم حالة Workflow حقيقية من السيرفر ثم قائمة المستندات المطابقة. مفيش أي Role أو اسم حالة متكوّد صلب |
| `customer_visits_screen.dart`, `credit_limit_request_screen.dart` | 🔲 Placeholder | مفيش أي نداء API، لسه "قريبًا" |

---

## 2) الـ Endpoints المستخدمة (نسخة مختصرة)

**مصادقة** (`mobile_control`, مُعطاة مباشرة، مش من OpenAPI):
`login` / `refresh_token` / `logout` / `me` — `mobile_control.api.api_auth.*`. شكل رد `me()` **مؤكد بالكامل دلوقتي** (اتفحص فعليًا عبر الـ API): `name`, `user`, `full_name`, `roles` (List<String> — كل أدوار المستخدم), `permissions` (List of per-DocType CRUD flags), `mobile_form_names`, `offline_enabled`.

**REST قياسي** (`/api/resource/<DocType>`) — Read/Create/Update حسب الحاجة على: `Customer`, `Sales Order`, `Sales Invoice`, `Payment Entry`, `Material Request`, `Stock Entry`, `Item`, `Item Price`, `Payment Terms Template`, `Selling Settings`, `Company`, `Workflow`, `Workflow Document State`, `Expense Claim`, `Vehicle Log`, `GL Entry` (❓غير مؤكدة الحقول), `Notification Log`, `Comment` (بقت REST بعد ما كانت RPC — شوف تحت), `Treasury`, `Price List`, `Item Discount Limit` (child table مخصص على `Item` عبر `custom_role_discount_limits`), `User Permission` (فلترة `allow=Territory` — مؤكدة حية، بترجع territories المستخدم الحالي), `Sales Person` (`custom_user` — Custom Field جديد هذه الجولة، Link→User؛ السجل القياسي **مفيهوش أي Link لـ User أصلاً**، اتأكد ده بفحص حقيقي — `sales_person_name` كان بيطابق `User.full_name` حرفيًا بس من غير أي ربط برمجي).

**الأدوار الحقيقية بتاعة الموافقات** (مؤكدة من `GET /api/resource/Role`): `WF - Sales Rep` → `WF - Region Manager` → `WF - General Manager` (وموجود كمان `WF - Accounts Manager`).

**`Item.max_discount`** (Percent) — حقل قياسي موجود بالفعل، رقم ثابت مش متدرّج حسب الدور. التحقق منه بيتم على مستوى الصنف (`discount_percentage` في `Sales Order Item`/`Sales Invoice Item`)، مش على خصم المستند الكلي.

**RPC مؤكدة من erpnext-app-openapi**:
- `erpnext.accounts.party.get_party_details`
- `erpnext.selling.doctype.sales_order.sales_order.make_sales_invoice`
- `erpnext.accounts.doctype.sales_invoice.sales_invoice.make_sales_return`
- `erpnext.selling.doctype.customer.customer.make_payment_entry`
- `erpnext.accounts.doctype.payment_entry.payment_entry.get_outstanding_reference_documents` (شكل `args` الداخلي ❓)
- `erpnext.stock.doctype.material_request.material_request.make_in_transit_stock_entry` (مؤجَّل استبدالها)

**RPC مؤكدة من frappe-app-openapi**:
- `frappe.model.workflow.get_transitions` / `apply_workflow` — الأساس اللي بينيه عليه `ErpService.tryAutoProgress` **و** زرار "اسحب للإرسال" الجديد في `document_detail_screen.dart`.

**مش مؤكدة (custom app، تخمين اسم بنمط `<app>.api.<method>`)**:
- `red_app.api.get_customer_credit_status`

**اتغيّرت هذه الجولة**:
- ❌ `frappe.desk.form.utils.add_comment` (كان محتاج Desk Access، مرفوض دائمًا) → ✅ `POST /api/resource/Comment` عادي (`comment_type`, `reference_doctype`, `reference_name`, `content`).
- الموقع الجغرافي في Sales Order/Invoice: كان `custom_location_map` (GeoJSON) → بقى **`custom_location_url`** (رابط Google Maps بسيط `https://www.google.com/maps?q=lat,lng`، بناءً على تعليمات المستخدم مباشرة — هو هيعمل Client Script سيرفر-سايد يحوّله لـ GeoJSON بنفسه). **ملاحظة**: `customer_registration_screen.dart` لسه بيستخدم `custom_location` (GeoJSON حقيقي) — حقل مختلف تمامًا، مش نفس الحاجة.

---

## 3) آخر مشكلة كنا بنحلها ونتيجتها

**المشكلة**: بعد ما اتحلت مشكلة "الطلبية بتتاعتمد نهائيًا على طول" (الجولة اللي فاتت — `tryAutoProgress` بقت فعل صريح بس عبر زرار "اسحب للإرسال")، المستخدم عايز يقفل ملف الطلبيات خالص بمجموعة تحسينات: منطقة العميل ظاهرة، المديونية الحالية ظاهرة جنب سقف الدين، وأهم حاجة — **حلقة الاعتماد الكاملة**: بعد ما المندوب يرسل الطلبية، مدير المنطقة (`WF - Region Manager`) يفتح نفس التطبيق من موبايله، يلاقي المستندات بانتظار موافقته، يراجعها بتفاصيلها الكاملة (أصناف + إجماليات)، يطبّق خصم لو عايز، ويعتمدها.

**الحل المُنفَّذ**:
1. **منطقة العميل** تحت اسمه في `customers_screen.dart` وكل الـ pickers الثلاثة، عبر `PickedRecord.subtitle` الموجود بالفعل.
2. **مفتاح "عملائي فقط"** في `customers_screen.dart` — لما يتقفل، فلتر `account_manager` بيتشال ويتم الاعتماد كليًا على صلاحيات السيرفر (Territory User Permission هيضبطها المستخدم بنفسه) — مفيد لمين عنده صلاحية أوسع (مدير منطقة).
3. **المديونية الحالية** تحت سقف الدين في `sales_order_screen.dart`/`sales_invoice_screen.dart` — دالة `_fetchCurrentOutstanding` مفصولة وقابلة لإعادة الاستخدام (تتنادى وقت الاختيار للعرض، وتاني وقت الإرسال للفحص الفعلي).
4. **`document_detail_screen.dart` بقت "كاملة" فعليًا**: قسم أصناف (يظهر تلقائيًا لو `doc['items']` موجودة، مش هاردكود)، قسم إجماليات (صافي/خصم/إجمالي نهائي)، وزرار "تعديل الخصم" (نسبة + قيمة) على Sales Order/Invoice — بيعتمد كليًا على السيرفر يرفض لو مفيش صلاحية Write.
5. **شاشة جديدة `pending_approvals_screen.dart`** — اكتشاف عام لأي مستند بانتظار موافقة: يختار Doctype، يختار حالة Workflow **حقيقية من السيرفر نفسه** (مش هاردكود)، تظهر قائمة المستندات، يفتح أي واحد فيها بنفس شاشة التفاصيل (بكل قدراتها الجديدة). مفيش أي اسم Role أو حالة متكوّد صلب في الكود.

**النتيجة**: ✅ `flutter analyze` صفر أخطاء/تحذيرات جديدة (9 اقتراحات `use_null_aware_elements` قديمة بس). ✅ `flutter test` 21/21. **لسه محتاج اختبار حقيقي على الجهاز** — مفيش أي preview حصل.

---

## 3.5) إصلاح فوري: فلتر `account_manager` كان بيمنع عملاء صحيحين

اختبار حقيقي كشف إن فلتر `account_manager` (جولة سابقة) كان بيمنع عملاء عندهم `territory` صحيح لكن مالهمش `account_manager` متسجّل — فلترتين بـ AND بدل فلتر واحد كافي. **اتشال بالكامل** من الـ pickers التلاتة، وبقت الثقة كليًا في صلاحيات السيرفر (Territory User Permission). مفتاح "عملائي فقط" في `customers_screen.dart` بقى مقفول افتراضيًا.

---

## 4) آخر مشكلة كنا بنحلها ونتيجتها

**المشكلة**: المستخدم عايز حدود خصم **متدرّجة حسب دور المستخدم لكل صنف على حدة** (مندوب/مدير منطقة/أعلى)، وكمان زرار "تعديل الخصم" الموجود كان بيهنج (من غير أي مؤشر تحميل وقت الحفظ).

**الحل المُنفَّذ**:
1. **إصلاح الهنج**: `document_detail_screen.dart` بقى فيه مؤشر تحميل + تعطيل الزرار وقت الحفظ (كان السبب إن الطلب بياخد وقت من غير أي رجع بصري، مش هنج حقيقي).
2. **المستخدم أدّاني API Key/Secret حقيقي (Administrator)** — استخدمته لفحص السيرفر مباشرة بدل التخمين، ولإنشاء الـ Schema المطلوب بنفسي (باتفاقه):
   - DocType جديد `Item Discount Limit` (child table، Module "Red App") + Custom Field `custom_role_discount_limits` على `Item`.
   - **اكتشاف حرج بالاختبار الفعلي**: تحديث `discount_percentage` لوحده على صنف بيترفض بصمت (يرجع لـ 0) — لازم `rate` تتحسب وتترسل مع بعض. اتأكد ده بتجربة حقيقية PUT على مستند تجريبي قبل ما يتكتب أي كود Flutter.
3. **أيقونة تعديل خصم جديدة لكل صنف** في قسم "الأصناف" — بتجيب حد الخصم المسموح لمستوى المستخدم الحالي (`WF - Sales Rep`/`WF - Region Manager`/`WF - General Manager`، عبر `AuthService.currentUserRoles()`/`resolveDiscountTier()` الجديدة) وتحذّر/تمنع لو تخطاه.

**فجوة موثّقة**: الإنفاذ الحقيقي غير القابل للالتفاف عليه لسه محتاج شغل سيرفر إضافي (`Item.max_discount` أو Python validation في `red_app`) — التطبيق بيوجّه ويحذّر بس، مش بديل عن حماية سيرفر-سايد حقيقية.

**النتيجة**: ✅ `flutter analyze`/`flutter test` نضيفين. Schema اتعمل واتأكد فعليًا عبر اختبار حي (إنشاء → كتابة → قراءة → تنظيف).

---

## 5) اختبار حقيقي على الجهاز — باگ حرج في الموافقات + دفعة طلبات كبيرة

المستخدم اختبر فعليًا على جهاز حقيقي ضد السيرفر الحقيقي وبعت تقرير فيه باگ حرج + مجموعة طلبات ميزات.

**الباگ الحرج (مُصلَح ومؤكَّد بدليل حقيقي)**: `ErpService.tryAutoProgress` كان بيعتبر أي رجوع فاضي/فاشل من `get_transitions` = "مفيش Workflow خالص"، فيعمل submit مباشر (`docstatus: 1`). لكن ده ممكن يحصل حتى لما يكون فيه Workflow حقيقي (فشل مؤقت، doc محلي غير مكتمل، شرط `condition` ما اتوفقش). أثبتّ عبر `Version` (audit log حقيقي من السيرفر) لطلبية حقيقية (`SAL-ORD-2026-00009`) إن تحديث واحد غيّر `docstatus` 0→1 و`workflow_state` "مسودة"→"معتمد نهائيا" مع بعض، من غير أي `apply_workflow` — يعني تخطّي كامل لسلسلة الموافقات (مدير المنطقة → الحسابات → المدير العام). **الإصلاح**: قبل أي submit مباشر، لازم نتأكد فعليًا (عبر `ErpService.getWorkflowDefinition`، مش تخمين) إن مفيش Workflow نشط على النوع ده خالص — لو فيه، منعمل حاجة، نسيب المستند زي ما هو بدل ما نخترق دورة الموافقات.

**الطلبات المُنفَّذة هذه الجولة**:
1. **`Sales Person.custom_user`** (Custom Field جديد، Link→User) — ربط موثوق بين المستخدم الحالي وسجل Sales Person بتاعه (السجل القياسي مفيهوش أي Link لـ User أصلاً، اتأكد ده عبر فحص حقيقي). `ErpService.resolveCurrentSalesPerson()` بيملى `sales_team` تلقائيًا (100%) وقت إنشاء الطلبية.
2. **أيقونة ترس لفلترة العملاء بخط السير** — تظهر بس لو المستخدم عنده أكتر من territory واحد (`ErpService.getUserTerritories()` عبر `User Permission`، مؤكدة حية). توسعة عامة جديدة في `search_picker.dart` (`actionsBuilder`) تدعم أي أيقونة إضافية في أي picker.
3. **معاينة الدفعات بتواريخ ومبالغ حقيقية** بدل النسبة وعدد الأيام بس — حساب تقديري محلي (`credit_days`/`credit_months`/`due_date_based_on`) فوق تاريخ التسليم أو اليوم.
4. **الكمية = عداد (+/-)** بدل حقل نصي، في `sales_order_screen.dart`/`sales_invoice_screen.dart`.
5. **المخزن — يظهر تلقائي وقابل للتغيير**: اتأكد إن السيرفر أصلاً بيعمل auto-default لمخزن "سيارة المندوب" لو التطبيق مبعتش `warehouse`. أضفنا زرار اختياري لكل صنف يغيّره لو عايز، من غير ما نكسر الافتراضي الشغال.
6. **GPS إجباري** — مفيش API يفتح GPS "غصبًا" على أندرويد؛ أقصى حاجة ممكنة (اتنفذت): منع الإرسال تمامًا لحد ما الموقع يتحدد بنجاح، مع توجيه مباشر لإعدادات الموقع/التطبيق.
7. **تاب "كل الطلبيات"** — جوه شاشة "طلبية جديدة" نفسها (مش تاب مستقل في الهوم، بناءً على توجيه المستخدم)، بنفس نمط تابات `sales_invoice_screen.dart`. شاشة `all_sales_orders_screen.dart` جديدة (بدون Scaffold خاص بيها، متضمنة كـ tab).
8. **إعادة تصميم محرر خصم الصنف**: الحدود بقت بتتجاب مقدمًا (مش عند الضغط) وقت تحميل المستند، الأيقونة بقت **مخفية تمامًا** لأي صنف مفيهوش حد مطابق لدور المستخدم، والتحقق بقى **منع فعلي أثناء الكتابة** (زرار "حفظ" بيتعطل لو تخطى الحد) مش تحذير بعد الحفظ.
9. **تلميح تحت زرار "حفظ"** لما يكون معطل، يوضح السبب ("اختر عميل أولاً"/"أضف صنف واحد على الأقل") بدل التعطيل الصامت.

**فجوات موثّقة (مش مغطاة، اتقال صراحةً للمستخدم بدل ما تتخمّن)**:
- **تهنيج (ANR) حقيقي** في دايلوج "تعديل الخصم" — راجعت كل الكود المحتمل (regex الـ stripHtml، منطق mentions، أي كود GPS/Timer دوري) ومفيش حاجة فيها بتفسر تجمد 5 ثواني+. محتاج تريس ANR فعلي من الجهاز (`adb bugreport` أو تقارير الأعطال في إعدادات أندرويد) — **مؤجَّل** لحد ما يبقى متاح.
- إنفاذ حدود خصم الصنف لسه بيعتمد على التطبيق (client-side hard block) — مش على `Item.max_discount` أو Python validation سيرفر-سايد حقيقي.

**النتيجة**: ✅ `flutter analyze` صفر أخطاء/تحذيرات جديدة. ✅ `flutter test` 21/21. **لسه محتاج اختبار حقيقي على الجهاز** لكل البنود التسعة أعلاه.

**مؤجَّل، مش المرحلة الجاية**: استبدال تاب "استلام" (`material_request_screen.dart`) بشاشة Workflow حقيقية على `Stock Entry` — بانتظار جاهزية شغل السيرفر.
