# LeadPilot

LeadPilot is a Flutter app for managing student leads, call follow-ups, reminders, and contact details from one place.

## Features

- PIN-based first-time setup and returning-user unlock.
- Student directory with search and date/status filters.
- Add and edit student details, call notes, and attempt history.
- Follow-up reminders with local notifications.
- Call and WhatsApp actions from a student record.
- Save contacts or bulk-select records to save or export.
- Optional Google Sheets synchronization through Google Apps Script.

## Getting started

Install the Flutter SDK, then from the project directory run:

```sh
flutter pub get
flutter run
```

Run the checks with:

```sh
flutter analyze
flutter test
```

## Google Sheets setup

The Apps Script backend is in [`gas_backend/Code.gs`](gas_backend/Code.gs).

1. Create a Google Sheet for the student records.
2. Either bind the script to that spreadsheet or set `SPREADSHEET_ID` in `Code.gs`.
3. Deploy the script as a Web App and copy its deployment URL into LeadPilot's Google Sheets settings.

**Security note:** The current Apps Script `doGet` and `doPost` endpoints do not authenticate callers. `doGet` returns the sheet's student records. Do not use this backend with real student data while the Web App is accessible to unauthenticated users. Add and verify an authentication mechanism before deploying it for sensitive data.

## Project layout

```text
lib/main.dart             Flutter application
test/widget_test.dart     Widget and behavior tests
gas_backend/Code.gs       Google Apps Script Sheets backend
```
