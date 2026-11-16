"""Cross-platform SQL smoke checks against statements extracted from production Swift.
This does not compile Swift or replace XCTest.
"""
import re
import sqlite3
from pathlib import Path
root = Path(__file__).resolve().parents[1]
schema = (root / 'Vela/Data/BrowserSchema.swift').read_text(encoding='utf-8')
names = dict(re.findall(r'public static let (\w+Table) = "([^"]+)"', schema))
body = schema.split('public static let creationStatements: [String] = [', 1)[1].split('    ]', 1)[0]
tokens = re.findall(r'"""(.*?)"""|"([^"\n]+)"', body, re.S)
statements = []
for multi, single in tokens:
    sql = multi or single
    if not sql.strip().startswith('CREATE '): continue
    for key, value in names.items(): sql = sql.replace('\\(' + key + ')', value)
    statements.append(sql)
db = sqlite3.connect(':memory:')
for sql in statements: db.execute(sql)
assert len(statements) > 35
db.execute("INSERT INTO downloads (guid, request_url, suggested_file_name, status, created_at, updated_at, window_id, private_session_id, privacy_mode) VALUES ('a','https://example.com','file','running',0,0,'a','one','private')")
db.execute("INSERT INTO downloads (guid, request_url, suggested_file_name, status, created_at, updated_at, window_id, private_session_id, privacy_mode) VALUES ('b','https://example.com','file','running',0,0,'b','two','private')")
db.execute("DELETE FROM downloads WHERE privacy_mode = 'private' AND window_id = ? AND private_session_id = ?", ('a','one'))
assert db.execute('SELECT guid FROM downloads').fetchall() == [('b',)]
db.commit()
try:
    db.execute('BEGIN IMMEDIATE')
    db.execute('ALTER TABLE downloads ADD COLUMN rollback_probe TEXT')
    db.execute('ALTER TABLE downloads ADD COLUMN guid TEXT')
except sqlite3.OperationalError:
    db.rollback()
assert 'rollback_probe' not in [r[1] for r in db.execute('PRAGMA table_info(downloads)')]
assert db.execute('SELECT guid FROM downloads').fetchall() == [('b',)]
print(f'PASS: {len(statements)} production schema statements; owner-scoped deletion; DDL rollback and data retention. Swift/XCTest not executed.')
