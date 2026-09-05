# RedLine

Mobile field-sales application for sales representatives, built with Flutter and integrated directly with an ERPNext/Frappe backend. Developed by Red Tech For Technology.

## Overview

RedLine is the mobile extension of an ERPNext deployment for a field sales team. It lets representatives create and manage sales documents, collect payments, register and visit customers, submit expenses, and track approvals from their phones — with full offline support for the operations that don't require a live server round trip. The interface is Arabic (RTL) throughout, built for field use in the MENA region.

## Features

### Sales and Orders
- Create, edit, and track Sales Orders, with automatic credit-limit checking against a customer's outstanding balance.
- Sales Invoices with immediate stock deduction, return support, and payment-schedule handling.
- On-device PDF generation for orders and invoices, shareable directly from the app with no server round trip required.
- GPS location capture attached to orders and invoices as proof of where they were created.

### Payments and Collections
- Customer payment collection against outstanding invoices, with correct per-payment-term due dates and treasury (cash/bank/mode of payment) selection.
- Document-level and per-item discount editing, gated to region managers and above with configurable per-item discount limits — never exposed to sales reps.
- Treasury and treasury statement views for tracking cash and bank movements.

### Customer Management
- Customer registration with GPS-tagged location, credit limits, price lists, and payment terms.
- Customer list with territory-based filtering, scoped automatically to a rep's own territory or a region manager's full set of sub-territories.
- Full customer account statement (GL-based), with expandable transaction detail and PDF export.
- Customer visit logging (visit, collection, or reactivation), with GPS capture and a calendar view of all recorded visits.
- Overdue-customer tracking based on configurable visit-frequency rules per territory.

### Field Operations
- Material request creation and a two-leg warehouse transfer workflow: a rep requests a transfer, a warehouse keeper prepares and ships it, and the rep confirms receipt.
- Vehicle expense logging (fuel and maintenance) via linked Vehicle Log and Expense Claim records, automatically submitted together.
- Personal expense claims with automatic resolution of the approver, cost center, and payable account.
- Stock movement tracking screen.

### Approvals and Workflow
- Full support for ERPNext's native document workflows — multi-level approval chains (region manager, accounts, general manager), with role-based transitions.
- A generic pending-approvals screen across every workflow-enabled document type, with bulk approval support.
- In-app notification center backed by Frappe's Notification Log, with an unread-count badge on the home screen and tap-to-open navigation straight to the relevant document.

### Dashboards and Reporting
- Home dashboard with quick actions, a recent-activity feed, and role-aware navigation (separate views for sales reps and region managers).
- Team dashboard for region managers: per-rep sales, collections, expenses, outstanding debt, and visit-count, each independently sortable — deliberately presented as separate metrics rather than a single composite score.
- Due-invoices calendar view, scoped by territory.

### Offline Mode
- Full offline queueing for document creation: sales orders, customer visits, material requests, customer registration, and expense claims (including the vehicle-log chain) can all be created without a network connection.
- Queued actions are stored in a local database and automatically retried in order as soon as connectivity is confirmed — verified with a real reachability check against the server, not just a network-interface signal.
- A dedicated sync queue screen shows every pending, failed, or completed action, with manual retry and discard controls.
- A persistent status indicator across the app shows connection state and pending-item count at all times.
- Read-through offline caching for reference data (customer statements, due invoices), with a clear "last updated" indicator whenever data is being shown from cache rather than a live fetch.
- Photos attached to documents while offline are stored locally and uploaded automatically once connectivity returns, then removed from the device.
- Financially sensitive operations that require a live server check — invoice creation, payment collection, and immediate stock transfers — intentionally remain online-only to prevent conflicting concurrent updates (e.g. two reps exceeding a shared credit limit).

### Security
- Domain-based login against the configured ERPNext instance, with secure token storage and automatic session refresh.
- Biometric (fingerprint) unlock as a fast, secure alternative to re-entering credentials.

## Screenshots

<div align="center">
  <img src="assets/screenshot/image%20(1).png" width="22%" />
  <img src="assets/screenshot/image%20(2).png" width="22%" />
  <img src="assets/screenshot/image%20(3).png" width="22%" />
  <img src="assets/screenshot/image%20(4).png" width="22%" />
  <br/>
  <img src="assets/screenshot/image%20(5).png" width="22%" />
  <img src="assets/screenshot/image%20(6).png" width="22%" />
  <img src="assets/screenshot/image%20(7).png" width="22%" />
  <img src="assets/screenshot/image%20(8).png" width="22%" />
  <br/>
  <img src="assets/screenshot/image%20(9).png" width="22%" />
  <img src="assets/screenshot/image%20(10).png" width="22%" />
  <img src="assets/screenshot/image%20(11).png" width="22%" />
  <img src="assets/screenshot/image%20(12).png" width="22%" />
  <br/>
  <img src="assets/screenshot/image%20(13).png" width="22%" />
  <img src="assets/screenshot/image%20(14).png" width="22%" />
</div>

## Technology

- **Framework:** Flutter (stable channel), Dart SDK ^3.12.2
- **Backend:** ERPNext / Frappe, accessed via its REST and RPC APIs
- **Local storage:** Drift (SQLite) for the offline queue and reference-data cache
- **Networking:** Dio, with automatic session-refresh handling
- **Navigation:** go_router
- **Connectivity:** connectivity_plus, backed by a real server reachability check
- **Other:** flutter_secure_storage, local_auth, geolocator, image_picker, printing/pdf, device_calendar

## Installation and Running

### Prerequisites
- Flutter SDK, stable channel (developed against 3.47.1)
- Dart SDK ^3.12.2 (bundled with the matching Flutter SDK)
- Android Studio (for Android) or Xcode (for iOS)
- An ERPNext backend with the corresponding custom API endpoints and DocTypes configured

### Steps to Run Locally

1. **Clone the repository:**
   ```bash
   git clone <repository-url>
   cd red_erp
   ```

2. **Install dependencies:**
   ```bash
   flutter pub get
   ```

3. **Generate local-database code** (required after any change to `lib/local_db/`):
   ```bash
   dart run build_runner build --delete-conflicting-outputs
   ```

4. **Run the application:**
   ```bash
   flutter run
   ```

5. **Build for production:**
   - **Android:**
     ```bash
     flutter build apk --release
     # or for Google Play
     flutter build appbundle --release
     ```
   - **iOS:**
     ```bash
     flutter build ipa
     ```

## Contributing

Contributions are welcome. To contribute:

1. Fork the repository.
2. Create a branch for your feature or fix (`git checkout -b feature/your-feature`).
3. Commit your changes with clear, descriptive messages.
4. Push the branch and open a pull request describing your changes.

Please ensure your code follows the linting rules defined in `analysis_options.yaml` and that `flutter analyze` and `flutter test` both pass before submitting.

## License

This project is licensed under the GPL-3.0 License - see the LICENSE file for details.