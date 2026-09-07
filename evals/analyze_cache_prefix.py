"""Audit append-only request transitions and provider-reported cache regressions."""
from __future__ import annotations
import argparse
import json
from pathlib import Path


def compare(previous, current, previous_usage, current_usage):
    changed = sorted(k for k in previous.keys() | current.keys()
                     if k != 'input' and previous.get(k) != current.get(k))
    old, new = previous.get('input', []), current.get('input', [])
    common = 0
    for a, b in zip(old, new):
        if a != b:
            break
        common += 1
    ordered_fields = sorted(k for k in previous.keys() & current.keys()
                            if k != 'input' and json.dumps(previous[k]) != json.dumps(current[k]))
    ordered_input = json.dumps(old) == json.dumps(new[:len(old)])
    stable = not changed and common == len(old)
    drop = previous_usage['cached_tokens'] - current_usage['cached_tokens']
    return {'stable_prefix': stable, 'changed_fields': changed,
            'previous_input_items': len(old), 'preserved_input_items': common,
            'recorded_object_order_stable': not ordered_fields and ordered_input,
            'recorded_order_changed_fields': ordered_fields,
            'previous_cached_tokens': previous_usage['cached_tokens'],
            'cached_tokens': current_usage['cached_tokens'],
            'cache_drop_tokens': max(drop, 0),
            'unchanged_prefix_cache_drop': stable and drop > 0}


def audit(root):
    transitions, skipped, usage_mismatches = [], [], []
    for path in sorted(root.rglob('provider-request-*.json')):
        try:
            n = int(path.stem.rsplit('-', 1)[1])
            if n <= 1:
                continue
            prev = path.with_name(f'provider-request-{n-1:04d}.json')
            a, b = json.loads(prev.read_text()), json.loads(path.read_text())
            pu = json.loads(path.with_name(f'response-{n-1:04d}.json').read_text())['_usage']
            cu = json.loads(path.with_name(f'response-{n:04d}.json').read_text())['_usage']
            raw = cu.get('raw_usage', {})
            details = raw.get('input_tokens_details', raw.get('prompt_tokens_details', {}))
            if details.get('cached_tokens') != cu['cached_tokens']:
                usage_mismatches.append(str(path))
            row = compare(a, b, pu, cu)
            row['request'] = str(path)
            if row['unchanged_prefix_cache_drop']:
                row['raw_attribution'] = raw.get('attribution', {}).get('request_fields', {})
            transitions.append(row)
        except (OSError, ValueError, KeyError, TypeError) as exc:
            skipped.append({'request': str(path), 'error': str(exc)})
    return {'transitions': len(transitions),
            'stable_prefix_transitions': sum(r['stable_prefix'] for r in transitions),
            'unchanged_prefix_drops': [r for r in transitions if r['unchanged_prefix_cache_drop']],
            'usage_mismatches': usage_mismatches, 'skipped': skipped,
            'limitation': 'Historical request JSON may have been decoded and re-encoded. Object order checks cannot prove historical wire-byte equality. Cache drops are observations, not backend cause diagnoses.'}

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    report = json.dumps(audit(args.root), indent=2) + '\n'
    if args.output:
        args.output.write_text(report)
    else:
        print(report, end='')
