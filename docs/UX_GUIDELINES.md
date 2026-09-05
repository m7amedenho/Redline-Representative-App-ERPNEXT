# إرشادات UX — Red ERP

ملخص من أفضل الممارسات (بحث ويب، أغسطس 2026) المطبّقة فعليًا على شاشات المشروع. أي تعديل مستقبلي على الشاشات الأربع أو ما بعدها يتبع هذه القواعد.

## 1. الاتجاه (RTL)

- Flutter يميّز أيقونات الاتجاه (`Icons.arrow_back`, `Icons.arrow_back_ios`) تلقائيًا حسب `Directionality` — لا داعي لعكسها يدويًا. الأيقونات غير الاتجاهية (مثل `check`, `person`) **لا** تُعكس ولا يجب إجبارها على ذلك.
- ممنوع استخدام `Alignment.topLeft` / `Alignment.centerRight` ...إلخ لتحديد مكان عناصر مرتبطة بمعنى "بداية/نهاية" الشاشة. استخدم `AlignmentDirectional.topStart` / `topEnd` حتى لو النتيجة البصرية الحالية متطابقة — لأن القيم الفيزيائية تنكسر أول ما يُدعم اتجاه LTR لاحقًا.
- نفس المبدأ على `Padding`/`EdgeInsets`: استخدم `EdgeInsetsDirectional` عند وجود فرق منطقي بين الجانبين، و`EdgeInsets.symmetric` عندما تكون القيمة متماثلة أصلاً.

**التطبيق:** زرار "تخطي" في Onboarding انتقل من `Alignment.topLeft` إلى `AlignmentDirectional.topEnd`.

المصادر: [Flutter and Directionality](https://medium.com/@carlolucera/flutter-and-directionality-d9ac42197fb8) · [Right to Left in Flutter Apps](https://leancode.co/blog/right-to-left-in-flutter-app)

## 2. نماذج الدخول (Login / Auth)

- التحقق يبدأ عند أول محاولة إرسال، ثم يتحول لحي (live) مع كل تعديل — لا تحقق فوري من أول حرف يكتبه المستخدم.
- رسالة الخطأ تظهر أسفل الحقل مباشرة (اتجاه القراءة الطبيعي)، مصحوبة بأيقونة، وتُعلن لقارئ الشاشة (`liveRegion`).
- استخدم `AutofillHints` + `AutofillGroup` لدعم مدراء كلمات المرور/الإكمال التلقائي بدل إجبار المستخدم على الكتابة يدويًا كل مرة.
- رحلة لوحة المفاتيح: `textInputAction` متسلسل (التالي → التالي → تم) مع `FocusNode` لكل حقل، بدل ما يضطر المستخدم يلمس كل حقل بإيده.
- زر الإجراء الأساسي (تسجيل الدخول) **يبقى لمسة عادية وليس سحب** — السحب (`SwipeToConfirmButton`) محجوز فقط للإجراءات الحساسة/النهائية (إرسال فاتورة، تأكيد تحصيل)، ليه إحساس مختلف عن الدخول العادي.
- أي زر لا يوجد له تنفيذ فعلي بعد (مثل "هل نسيت كلمة المرور؟") يجب أن يعطي feedback مرئي (SnackBar) بدل ما يكون "ميت" — تفاعل بدون رد فعل مرئي يُفهم كـ"العنصر معطّل/به خطأ".

المصادر: [Login & Signup UX 2025](https://www.authgear.com/post/login-signup-ux-guide/) · [Error Feedback on Mobile Forms](https://www.uxpin.com/studio/blog/error-feedback-best-practices-mobile-forms/)

## 3. الـ Onboarding

- زر "تخطي" لازم يكون واضح وظاهر (مش مخفي في زاوية باهتة)، خصوصًا لو عدد الشاشات ≥ 3.
- مؤشر تقدّم (dots) ضروري عشان المستخدم يعرف بعده كام شاشة.
- لا تُجبر المستخدم على تعبئة بيانات في هذه المرحلة — هي تعريف فقط.

**الحالة الحالية:** 3 شاشات + Skip ظاهر + dots متحركة → مطابق للمعيار. تمت إضافة `Semantics` على مؤشر الصفحات لقارئ الشاشة ("صفحة X من 3").

المصادر: [Mobile App Onboarding Best Practices](https://www.eleken.co/blog-posts/mobile-app-onboarding-best-practices)

## 4. زر "اسحب للتأكيد" (Swipe to Confirm)

- الاستخدام الصحيح: إجراءات حساسة/نهائية فقط (دفع، حذف، إرسال فاتورة) — وليس كل الأزرار.
- تغيير اللون (إلى أخضر) + تغيير النص أثناء السحب يعزز إحساس "الأمان والإنجاز".
- **تفاصيل تمت إضافتها الآن:**
  - Haptic feedback حقيقي: اهتزاز خفيف عند بداية السحب (`HapticFeedback.selectionClick`)، واهتزاز متوسط عند اكتمال التأكيد (`HapticFeedback.mediumImpact`) — إحساس ملموس بدل الاعتماد على البصر فقط.
  - Shimmer/pulse: 3 أسهم صغيرة أمام المقبض بتلمع بالتتابع (loop مستمر) بدل سهم واحد ثابت — بتلفت الانتباه لاتجاه السحب بشكل أقوى، وبتختفي تدريجيًا كل ما المستخدم يسحب المقبض جنبها.
  - `Semantics` label يشرح للمستخدم اللي بيستخدم قارئ شاشة إيه الإجراء ده، لأن السحب بالإيد وحده مش accessible بطبيعته (قيد معروف — البديل الكامل يحتاج زر تأكيد بديل عند تفعيل قارئ الشاشة، مؤجل لمرحلة قادمة).

المصادر: [Creating a Swipe-to-Confirm Component](https://www.arjunkalburgi.com/writing/creating-a-swipe-to-confirm-component/) · [Using Swipe to Trigger Contextual Actions — NN/G](https://www.nngroup.com/articles/contextual-swipe/)

## 5. الإشعارات (Notifications)

- أيقونة الجرس هي نقطة الدخول الوحيدة لمركز الإشعارات، والـ badge رقم بسيط "glanceable" لا يفرض تفاعل فوري.
- كل صف إشعار لازم يجاوب بصريًا وبسرعة على سؤال "إيه ده، وهل يهمني؟": أيقونة توضح النوع + عنوان قائم بذاته + سطر وصف مختصر (سطرين كحد أقصى) + وقت نسبي.
- في الشاشات الضيقة تكبر مساحة اللمس لكل صف لتكون ≥ 44px.

**التطبيق:** الجرس في الهيدر أصبح فعليًا (كان بدون `onTap` نهائيًا) وينقل لشاشة إشعارات كاملة (`/notifications`)، مع تحديث الـ badge (يختفي بعد الزيارة) عبر إرجاع نتيجة من الشاشة عند الرجوع.

المصادر: [Notification UX: 8 Best Practices](https://www.eleken.co/blog-posts/notification-ux) · [In-app notification center design — Courier](https://www.courier.com/blog/in-app-notification-center-design)

## 6. شريط التنقل السفلي (Bottom Navigation)

- 3–5 عناصر كحد أقصى (عندنا 5 = الحد الأعلى المسموح، لا نزيد عليه).
- كل عنصر يمثل وجهة "من المستوى الأول" فعلية، مش أكشن ثانوي.
- أي تبويب لسه مبنيش محتواه الفعلي (الطلبيات/الخزنة/الحساب في هذه المرحلة) لازم يدي feedback واضح (مؤقتًا: SnackBar "قيد التطوير") بدل ما يتغير لون الأيقونة بس من غير أي رد فعل — تفاعل صامت = إحساس بالعطل.

المصادر: [Bottom Tab Bar Navigation Design Best Practices](https://uxdworld.com/bottom-tab-bar-navigation-design-best-practices/)

## 7. مساحات اللمس وإمكانية الوصول (Touch Targets & A11y)

- الحد الأدنى المعتمد في المشروع: **48×48dp** (توصية Material) لأي عنصر لمس تفاعلي — أعلى من حد WCAG الأدنى (24px) ومطابق لتوصية Apple (44pt) تقريبًا.
- أي أيقونة تفاعلية بدون نص مجاور (الجرس، زر إظهار/إخفاء كلمة المرور، الأفاتار) لازم يكون ليها `Semantics`/`tooltip` تشرح وظيفتها لقارئ الشاشة.
- تباين الألوان: النص الأبيض على الأسود/الأحمر الغامق `#D62828`، والأسود على الأبيض/الرمادي الفاتح — كلها تتخطى حد التباين WCAG AA بمسافة كبيرة، فلا حاجة لتغيير لوحة الألوان الحالية.

المصادر: [Mobile Touch Target Size Guide 2026](https://www.accessitool.com/blog/mobile-touch-target-size-complete-guide-fixes-accessibility-2026) · [WCAG 2.5.8 Target Size](https://www.allaccessible.org/blog/wcag-258-target-size-minimum-implementation-guide)

---

## قائمة التطبيق الفعلي (Checklist)

- [x] Onboarding: `AlignmentDirectional.topEnd` بدل `Alignment.topLeft` لزر التخطي.
- [x] Onboarding: `Semantics` على مؤشر الصفحات.
- [x] Auth: `AutovalidateMode.onUserInteraction` بعد أول محاولة إرسال.
- [x] Auth: `AutofillGroup` + `AutofillHints.username/password`.
- [x] Auth: تسلسل `FocusNode`/`textInputAction` بين الحقول الثلاثة.
- [x] Auth: رسالة الخطأ مع أيقونة + `Semantics(liveRegion: true)`.
- [x] Auth: "هل نسيت كلمة المرور؟" يعطي SnackBar بدل ما يكون بلا أي رد فعل.
- [x] Swipe-to-Confirm: Haptic feedback عند بداية السحب واكتمال التأكيد.
- [x] Swipe-to-Confirm: `Semantics` label توضيحي.
- [x] Swipe-to-Confirm: أسهم shimmer/pulse متتابعة أمام المقبض بدل سهم ثابت.
- [x] اللوجو الرسمي (`assets/logo.svg`) بدّل الأيقونات المؤقتة في Splash وشارة تسجيل الدخول، بلون أبيض تلقائي فوق أي خلفية غامقة.
- [x] Home: أيقونة الجرس فعليًا تفتح شاشة إشعارات حقيقية + تحديث الـ badge.
- [x] Home: تبويبات الشريط السفلي غير المبنية بعد تعطي SnackBar توضيحي بدل تفاعل صامت.
- [x] Home/عام: مساحات لمس ≥ 48dp لكل الأيقونات التفاعلية.
