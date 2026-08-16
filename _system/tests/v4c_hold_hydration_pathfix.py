#!/usr/bin/env python3
import sys
from pathlib import Path

import v4c_hold_hydration as hydration

_original_hydrate_one = hydration.hydrate_one


def _missing_artifact(row, evidence_repo_path):
    return {
        'schema_version': hydration.SCHEMA,
        'sequence': int(row['sequence']),
        'source_id': row.get('source_id'),
        'product_id': row.get('product_id'),
        'sha256': row.get('expected_sha256'),
        'evidence_origin': 'B001_B018_ARTIFACT',
        'image_metadata': {},
        'ocr': {'texts': []},
        'script_classification': {},
        'localization_state': 'MISSING_ARTIFACT_VISUAL',
        'claim_candidates': [],
        'verified_claims': [],
        'unknown_claims': [],
        'evidence_location': {'durable': evidence_repo_path},
        'preservation_decision': 'HOLD',
        'confidence': {'preservation': 0.0},
        'claim_gate_status': 'HOLD',
        'terminal_status': 'HOLD',
        'flags': hydration.flags(False, False, False),
    }


def safe_hydrate_one(row, models, ctx, sem_map, pres_map, cache_dir, evidence_repo_path):
    if str(row.get('hydration_action')) == 'USE_B001_B018_VISUAL':
        raw_path = str(row.get('artifact_local_path') or '').strip()
        if not raw_path:
            return _missing_artifact(row, evidence_repo_path)
        artifact_path = Path(raw_path)
        if not artifact_path.is_file():
            return _missing_artifact(row, evidence_repo_path)
    return _original_hydrate_one(row, models, ctx, sem_map, pres_map, cache_dir, evidence_repo_path)


def selftest():
    row = {
        'sequence': 1,
        'source_id': 'fixture',
        'product_id': 'fixture',
        'expected_sha256': '0' * 64,
        'hydration_action': 'USE_B001_B018_VISUAL',
        'artifact_local_path': '',
    }
    rec = safe_hydrate_one(row, None, {}, {}, {}, 'cache', '_system/v4c/evidence_hydration/evidence.jsonl')
    assert rec['terminal_status'] == 'HOLD'
    assert rec['localization_state'] == 'MISSING_ARTIFACT_VISUAL'
    assert rec['flags']['ocr_executed'] is False
    print('V4C2_3_EMPTY_ARTIFACT_PATH_FIXED=true')
    print('EMPTY_PATH_TO_DOT_READ_BYTES=false')


hydration.hydrate_one = safe_hydrate_one

if __name__ == '__main__':
    if len(sys.argv) == 2 and sys.argv[1] == 'pathfix-self-test':
        selftest()
        sys.exit(0)
    sys.exit(hydration.main())
