"""Check the school directory's persisted inputs independently of generated queries."""

import hashlib
import json
from pathlib import Path
import sqlite3
import sys


def stored(database):
    with sqlite3.connect(database.resolve().as_uri() + '?mode=ro&immutable=1', uri=True) as db:
        assert db.execute('PRAGMA quick_check').fetchone() == ('ok',)
        rows = {
            'districts': db.execute('SELECT id,version,name FROM district_data ORDER BY id').fetchall(),
            'schoolTypes': db.execute('SELECT id,version,name,district FROM school_type_data ORDER BY id').fetchall(),
            'schools': db.execute('SELECT id,version,name,school_type,class_count,active,registry_number '
                                  'FROM school_data ORDER BY id').fetchall(),
        }
    assert rows == {
        'districts': [(1, 1, 'River District')],
        'schoolTypes': [(1, 1, 'Primary', 1), (2, 1, 'Secondary', 1)],
        'schools': [(1, 1, 'Cedar Primary', 1, 1, 0, 9007199254740993),
                    (2, 1, 'Riverside Primary', 1, 2, 1, 9007199254740993),
                    (3, 1, 'Harbor Secondary', 2, 3, 1, 9007199254740993),
                    (4, 1, 'Hill School', None, 4, 1, 9007199254740993)],
    }, rows
    return rows


def dependency_paths(node):
    if node.get('path'):
        yield Path(node['path']).resolve()
    for dependency in node.get('dependencies', []):
        yield from dependency_paths(dependency)


def finish(database, runtime, rows):
    directory = database.parent
    text = (directory / 'dependencies.log').read_text()
    start = text.find('{')
    assert start >= 0, text[-1000:]
    dependency_tree, _ = json.JSONDecoder().raw_decode(text[start:])
    assert list(dependency_paths(dependency_tree)).count(runtime.resolve()) == 1
    result = json.loads((directory / 'result.json').read_text())
    assert result == dict(passed=True, rounds=2, casesPerRound=11,
                          generatedMutations=6, reseededInSecondRound=0)
    names = ['dependencies.log', 'result.json', 'round-1.log', 'round-2.log',
             'rows-1.json', 'rows-2.json', database.name]
    receipt = dict(schema='teaql.swift-school-grouping-business/v1', passed=True, sameDatabase=True,
                   localRuntime=str(runtime.resolve()), persistedRows=rows, **{
                       k: v for k, v in result.items() if k != 'passed'
                   })
    receipt['evidenceSHA256'] = {name: hashlib.sha256((directory / name).read_bytes()).hexdigest() for name in names}
    with (directory / 'business-receipt.json').open('x') as output:
        json.dump(receipt, output, indent=2, sort_keys=True)
        output.write('\n')


if __name__ == '__main__':
    database = Path(sys.argv[1])
    rows = stored(database)
    if len(sys.argv) == 2:
        print(json.dumps(rows, sort_keys=True))
    else:
        finish(database, Path(sys.argv[2]), rows)
