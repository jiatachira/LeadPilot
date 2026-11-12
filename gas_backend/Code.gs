const SPREADSHEET_ID = '';
const SHEET_NAME = 'Students';
const FIXED_HEADERS = [
  'Name',
  'Contact',
  'Source',
  'Added Date',
  'Exam Type',
  'Exam Year',
  'Location',
  'OL English',
  'OL Maths',
  'WhatsApp',
  'Next Call Date',
];
const ATTEMPT_HEADERS = ['Date/Time', 'Call Status', 'Comment'];

function doGet() {
  try {
    const sheet = getStudentSheet_();
    ensureHeaders_(sheet);
    const lastRow = sheet.getLastRow();
    if (lastRow < 2) {
      return jsonOutput_({ success: true, students: [] });
    }

    const width = Math.max(sheet.getLastColumn(), FIXED_HEADERS.length);
    const rows = sheet.getRange(2, 1, lastRow - 1, width).getValues();
    const displayedContacts = sheet
      .getRange(2, 2, lastRow - 1, 1)
      .getDisplayValues();
    const students = rows
      .map((row, index) => {
        row[1] = displayedContacts[index][0];
        return row;
      })
      .filter((row) => text_(row[1]) !== '')
      .map((row) => studentFromRow_(row));
    return jsonOutput_({ success: true, students: students });
  } catch (error) {
    return jsonOutput_({ success: false, error: error.message });
  }
}

function doPost(event) {
  try {
    if (!event || !event.postData || !event.postData.contents) {
      throw new Error('Request body must contain a JSON object.');
    }

    const payload = JSON.parse(event.postData.contents);
    const contact = text_(payload.contact || payload.phone);
    const name = text_(payload.name);
    if (!contact) {
      throw new Error('Contact number is required.');
    }
    if (!name) {
      throw new Error('Student name is required.');
    }

    const sheet = getStudentSheet_();
    ensureHeaders_(sheet);
    const previousContact = text_(payload.previousContact || contact);
    const lookupContact = payload.action === 'update'
      ? previousContact
      : contact;
    const existingRow = findStudentRow_(sheet, lookupContact);
    if (payload.action === 'update' && !existingRow) {
      throw new Error(
        'No student with the original contact number was found. The update was not added as a new row.',
      );
    }
    if (
      payload.action === 'update' &&
      normalizeContact_(contact) !== normalizeContact_(previousContact)
    ) {
      const duplicateRow = findStudentRow_(sheet, contact);
      if (duplicateRow && duplicateRow !== existingRow) {
        throw new Error(
          'Another student already uses the new contact number. The existing row was not changed.',
        );
      }
    }
    const rowNumber = existingRow || sheet.getLastRow() + 1;
    const existing = existingRow
      ? sheet.getRange(rowNumber, 1, 1, FIXED_HEADERS.length).getValues()[0]
      : new Array(FIXED_HEADERS.length).fill('');

    const fixedValues = [
      field_(payload, 'name', existing[0]),
      contact,
      field_(payload, 'source', existing[2]),
      field_(payload, 'addedDate', existing[3]),
      field_(payload, 'examType', existing[4]),
      field_(payload, 'examYear', field_(payload, 'age', existing[5])),
      field_(payload, 'location', existing[6]),
      field_(payload, 'olEnglish', existing[7]),
      field_(payload, 'olMaths', existing[8]),
      field_(payload, 'whatsappNumber', existing[9]),
      field_(payload, 'nextCallDateTime', existing[10]),
    ];

    // An empty string explicitly clears an existing next-call date.
    if (Object.prototype.hasOwnProperty.call(payload, 'nextCallDateTime')) {
      fixedValues[10] = text_(payload.nextCallDateTime);
    }
    sheet.getRange(rowNumber, 2).setNumberFormat('@');
    sheet.getRange(rowNumber, 1, 1, FIXED_HEADERS.length).setValues([fixedValues]);

    const attempts = attemptsFromPayload_(payload);
    const addedAttempts = appendNewAttempts_(sheet, rowNumber, attempts);
    return jsonOutput_({
      success: true,
      action: existingRow ? 'updated' : 'created',
      contact: contact,
      attemptsAdded: addedAttempts,
    });
  } catch (error) {
    return jsonOutput_({ success: false, error: error.message });
  }
}

function getStudentSheet_() {
  const spreadsheet = SPREADSHEET_ID
    ? SpreadsheetApp.openById(SPREADSHEET_ID)
    : SpreadsheetApp.getActiveSpreadsheet();
  if (!spreadsheet) {
    throw new Error(
      'No spreadsheet is linked. Bind this script to a spreadsheet or set SPREADSHEET_ID.',
    );
  }

  let sheet = spreadsheet.getSheetByName(SHEET_NAME);
  if (!sheet) {
    sheet = spreadsheet.insertSheet(SHEET_NAME);
  }
  return sheet;
}

function ensureHeaders_(sheet) {
  const fixedRange = sheet.getRange(1, 1, 1, FIXED_HEADERS.length);
  const currentHeaders = fixedRange.getValues()[0];
  if (currentHeaders.every((value) => text_(value) === '')) {
    fixedRange.setValues([FIXED_HEADERS]);
  } else if (
    currentHeaders.some(
      (value, index) =>
        text_(value) !== FIXED_HEADERS[index] &&
        !(index === 5 && text_(value) === 'Age'),
    )
  ) {
    throw new Error(
      'The first row does not match the required student columns A–K.',
    );
  } else if (text_(currentHeaders[5]) === 'Age') {
    sheet.getRange(1, 6).setValue('Exam Year');
  }
}

function findStudentRow_(sheet, contact) {
  const lastRow = sheet.getLastRow();
  if (lastRow < 2) {
    return 0;
  }

  const contacts = sheet
    .getRange(2, 2, lastRow - 1, 1)
    .getDisplayValues();
  const target = normalizeContact_(contact);
  for (let index = 0; index < contacts.length; index += 1) {
    if (normalizeContact_(contacts[index][0]) === target) {
      return index + 2;
    }
  }
  return 0;
}

function studentFromRow_(row) {
  const attempts = [];
  for (let column = FIXED_HEADERS.length; column < row.length; column += 3) {
    const dateTime = row[column];
    const status = row[column + 1];
    const comment = row[column + 2];
    if (
      text_(dateTime) !== '' ||
      text_(status) !== '' ||
      text_(comment) !== ''
    ) {
      attempts.push({
        dateTime: dateToString_(dateTime),
        status: text_(status),
        comment: text_(comment),
      });
    }
  }
  attempts.sort((left, right) =>
    dateValue_(left.dateTime) - dateValue_(right.dateTime),
  );

  const latestAttempt = attempts.length
    ? attempts[attempts.length - 1]
    : null;
  return {
    name: text_(row[0]),
    contact: text_(row[1]),
    source: text_(row[2]),
    addedDate: dateToString_(row[3]),
    examType: text_(row[4]),
    examYear: text_(row[5]),
    location: text_(row[6]),
    olEnglish: text_(row[7]),
    olMaths: text_(row[8]),
    whatsappNumber: text_(row[9]),
    nextCallDateTime: dateToString_(row[10]),
    callStatus: latestAttempt ? latestAttempt.status : 'Pending',
    comment: latestAttempt ? latestAttempt.comment : '',
    commentHistory: attempts
      .filter((attempt) => attempt.comment !== '')
      .map((attempt) =>
        dateToString_(attempt.dateTime) + ' — ' + attempt.comment,
      ),
    attempts: attempts,
  };
}

function attemptsFromPayload_(payload) {
  const attempts = Array.isArray(payload.attempts) ? payload.attempts : [];
  const normalized = attempts.map((attempt) => normalizeAttempt_(attempt));
  if (payload.latestAttempt) {
    normalized.push(normalizeAttempt_(payload.latestAttempt));
  } else if (
    !Object.prototype.hasOwnProperty.call(payload, 'attempts') &&
    payload.comment &&
    payload.callStatus
  ) {
    normalized.push({
      dateTime: new Date().toISOString(),
      status: text_(payload.callStatus),
      comment: text_(payload.comment),
    });
  }
  return normalized.filter(
    (attempt) => attempt.dateTime !== '' && attempt.status !== '',
  );
}

function appendNewAttempts_(sheet, rowNumber, attempts) {
  if (attempts.length === 0) {
    return 0;
  }

  const existingWidth = Math.max(
    sheet.getLastColumn() - FIXED_HEADERS.length,
    0,
  );
  const existingCells =
    existingWidth > 0
      ? sheet
          .getRange(rowNumber, FIXED_HEADERS.length + 1, 1, existingWidth)
          .getValues()[0]
      : [];
  const known = {};
  const existingAttempts = [];
  for (let offset = 0; offset < existingCells.length; offset += 3) {
    const attempt = {
      dateTime: dateToString_(existingCells[offset]),
      status: text_(existingCells[offset + 1]),
      comment: text_(existingCells[offset + 2]),
    };
    if (attempt.dateTime !== '' || attempt.status !== '' || attempt.comment !== '') {
      existingAttempts.push(attempt);
      known[attemptKey_(attempt)] = true;
    }
  }

  const newAttempts = [];
  attempts.forEach((attempt) => {
    const key = attemptKey_(attempt);
    if (!known[key]) {
      known[key] = true;
      newAttempts.push(attempt);
    }
  });
  if (newAttempts.length === 0) {
    return 0;
  }

  const firstAttemptColumn = FIXED_HEADERS.length + 1;
  let nextColumn = firstAttemptColumn + existingAttempts.length * 3;
  const rowWidth = Math.max(sheet.getLastColumn(), firstAttemptColumn - 1);
  if (rowWidth >= firstAttemptColumn) {
    const occupied = sheet
      .getRange(rowNumber, firstAttemptColumn, 1, rowWidth - firstAttemptColumn + 1)
      .getValues()[0];
    let lastOccupiedOffset = -1;
    occupied.forEach((value, offset) => {
      if (text_(value) !== '') {
        lastOccupiedOffset = offset;
      }
    });
    nextColumn = Math.max(
      nextColumn,
      firstAttemptColumn + Math.ceil((lastOccupiedOffset + 1) / 3) * 3,
    );
  }

  const values = [];
  newAttempts.forEach((attempt) => {
    values.push(attempt.dateTime, attempt.status, attempt.comment);
  });
  sheet.getRange(rowNumber, nextColumn, 1, values.length).setValues([values]);

  newAttempts.forEach((_, index) => {
    const attemptColumn = nextColumn + index * 3;
    const headerColumn = attemptColumn;
    sheet
      .getRange(1, headerColumn, 1, ATTEMPT_HEADERS.length)
      .setValues([ATTEMPT_HEADERS]);
  });
  return newAttempts.length;
}

function normalizeAttempt_(attempt) {
  if (!attempt || typeof attempt !== 'object') {
    return { dateTime: '', status: '', comment: '' };
  }
  return {
    dateTime: dateToString_(attempt.dateTime),
    status: text_(attempt.status),
    comment: text_(attempt.comment),
  };
}

function attemptKey_(attempt) {
  return JSON.stringify([
    Math.floor(dateValue_(attempt.dateTime) / 1000),
    attempt.status,
    attempt.comment,
  ]);
}

function field_(payload, key, fallback) {
  return Object.prototype.hasOwnProperty.call(payload, key)
    ? payload[key]
    : fallback;
}

function normalizeContact_(contact) {
  let digits = text_(contact).replace(/\D/g, '');
  if (digits.startsWith('00')) {
    digits = digits.substring(2);
  }
  if (digits.startsWith('94') && digits.length === 11) {
    digits = digits.substring(2);
  }
  if (digits.startsWith('0') && digits.length === 10) {
    digits = digits.substring(1);
  }
  return digits;
}

function text_(value) {
  if (value === null || value === undefined) {
    return '';
  }
  return String(value).trim();
}

function dateToString_(value) {
  if (value === null || value === undefined || value === '') {
    return '';
  }
  if (value instanceof Date && !isNaN(value.getTime())) {
    return Utilities.formatDate(
      value,
      Session.getScriptTimeZone(),
      "yyyy-MM-dd'T'HH:mm:ss",
    );
  }
  return text_(value);
}

function dateValue_(value) {
  if (value instanceof Date && !isNaN(value.getTime())) {
    return value.getTime();
  }
  const text = text_(value);
  const hasTimezone = /(?:Z|[+-]\d{2}:?\d{2})$/i.test(text);
  const isoWithoutTimezone =
    /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?$/.test(text);
  const parsed =
    !hasTimezone && isoWithoutTimezone
      ? Utilities.parseDate(
          text.substring(0, 19),
          Session.getScriptTimeZone(),
          "yyyy-MM-dd'T'HH:mm:ss",
        ).getTime()
      : new Date(text).getTime();
  return isNaN(parsed) ? 0 : parsed;
}

function jsonOutput_(value) {
  return ContentService.createTextOutput(JSON.stringify(value)).setMimeType(
    ContentService.MimeType.JSON,
  );
}
