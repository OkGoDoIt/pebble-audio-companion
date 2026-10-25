#!/usr/bin/env python3
"""Apply a frozen policy to low-threshold score export; never changes any corpus labels."""
import json
import pathlib
import sys

report = json.loads(pathlib.Path(sys.argv[1]).read_text())
metadata = {r['id']: r for r in json.loads(pathlib.Path(sys.argv[2]).read_text())}
threshold = float(sys.argv[3]) if len(sys.argv) > 3 else .55
margin = float(sys.argv[4]) if len(sys.argv) > 4 else .10
if report['policy']['minimumSimilarity'] > threshold or report['policy']['minimumMargin'] > margin:
    raise ValueError('Cannot recover rejected identities when relaxing an already applied policy')
counts = dict(known=0, unknown=0, correctlyNamed=0, incorrectlyNamed=0, knownAbstained=0, unknownRejected=0)
for identifier, decision in report['decisions'].items():
    truth = metadata[identifier]['personID']
    accepted = decision.get('score', -1) >= threshold and decision.get('margin', 2) >= margin
    winner = decision.get('personID') if accepted else None
    if truth is None:
        counts['unknown'] += 1
        counts['incorrectlyNamed' if winner else 'unknownRejected'] += 1
    else:
        counts['known'] += 1
        counts['knownAbstained' if winner is None else 'correctlyNamed' if truth.lower() == winner.lower() else 'incorrectlyNamed'] += 1
print(json.dumps(dict(policy=dict(minimumSimilarity=threshold, minimumMargin=margin, minimumExamples=2), counts=counts), indent=2))
