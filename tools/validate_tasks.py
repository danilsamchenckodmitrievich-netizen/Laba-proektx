#!/usr/bin/env python3
"""Validate the public task catalog, solution references and local SVG assets."""
import json
from pathlib import Path
import sys
import xml.etree.ElementTree as ET

from jsonschema import Draft202012Validator

ROOT = Path(__file__).resolve().parents[1]


def load(path):
    return json.loads((ROOT / path).read_text(encoding='utf-8'))


def validate_catalog(catalog, solutions, root=ROOT):
    errors = []
    for document, schema_file in [(catalog, 'task-catalog.schema.json'), (solutions, 'task-solutions.schema.json')]:
        schema = load('schemas/' + schema_file)
        Draft202012Validator.check_schema(schema)
        for error in Draft202012Validator(schema).iter_errors(document):
            errors.append(f'{schema_file}:{"/".join(map(str, error.absolute_path))}: {error.message}')
    if errors:
        return errors
    subject_ids = [subject['id'] for subject in catalog['subjects']]
    if len(subject_ids) != len(set(subject_ids)):
        errors.append('Duplicate subject IDs')
    tasks = catalog['tasks']
    task_ids = [task['id'] for task in tasks]
    solution_ids = [solution['task_id'] for solution in solutions['solutions']]
    if len(task_ids) != len(set(task_ids)):
        errors.append('Duplicate task IDs')
    if len(solution_ids) != len(set(solution_ids)):
        errors.append('Duplicate solution references')
    if set(task_ids) != set(solution_ids):
        errors.append('Every task must have exactly one solution reference; orphan references are forbidden')
    for task in tasks:
        if task['subject'] not in subject_ids:
            errors.append(f'{task["id"]}: unknown subject {task["subject"]}')
        for illustration in task['illustrations']:
            path = root / illustration['src']
            if not path.is_file():
                errors.append(f'{task["id"]}: missing illustration {illustration["src"]}')
                continue
            try:
                svg = ET.parse(path).getroot()
                if svg.tag != '{http://www.w3.org/2000/svg}svg' or 'viewBox' not in svg.attrib:
                    errors.append(f'{path.name}: SVG must have a viewBox')
                for node in svg.iter():
                    if node.tag.rsplit('}', 1)[-1] in ('script', 'foreignObject'):
                        errors.append(f'{path.name}: active SVG content is forbidden')
                    for attr in node.attrib:
                        if attr.lower().startswith('on') or attr.rsplit('}', 1)[-1] == 'href':
                            errors.append(f'{path.name}: event handlers and external references are forbidden')
            except ET.ParseError as exc:
                errors.append(f'{path.name}: invalid SVG: {exc}')
    for solution in solutions['solutions']:
        symbols = [var['symbol'] for var in solution['variables']]
        if len(symbols) != len(set(symbols)):
            errors.append(f'{solution["task_id"]}: duplicate variable assumptions')
    return errors


if __name__ == '__main__':
    catalog = load('data/tasks/catalog.json')
    solutions = load('backend/data/task-solutions.json')
    issues = validate_catalog(catalog, solutions)
    for issue in issues:
        print(issue, file=sys.stderr)
    if issues:
        sys.exit(1)
    print(f'OK: {len(catalog["tasks"])} tasks, {len(solutions["solutions"])} solution references; schemas and illustrations valid.')
