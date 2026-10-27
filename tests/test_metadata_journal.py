"""Real Swift/filesystem subprocess tests. Two directories simulate replicas; no cloud or second Mac."""
import copy
import json
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import random
import shutil
import subprocess
import uuid

import pytest

ROOT = Path(__file__).resolve().parents[1]
TASK = '00000000-0000-4000-8000-000000000001'
GROUP = '00000000-0000-4000-8000-000000000002'
ACTOR_A = '00000000-0000-4000-8000-000000000003'
ACTOR_B = '00000000-0000-4000-8000-000000000004'


@pytest.fixture(scope='session')
def metadata_cli(tmp_path_factory):
    binary = tmp_path_factory.mktemp('swift-metadata') / 'MetadataProbe'
    run = subprocess.run(['swiftc', '-swift-version', '5', '-parse-as-library',
        str(ROOT/'poc/metadata-journal/OperationJournal.swift'),
        str(ROOT/'poc/metadata-journal/MetadataProbe.swift'), '-o', str(binary)],
        capture_output=True, text=True, timeout=90)
    assert run.returncode == 0, run.stderr
    return binary


def call(binary, command, directory, *args, expected=0):
    run = subprocess.run([str(binary), command, str(directory), *map(str, args)],
        capture_output=True, text=True, timeout=15)
    assert run.returncode == expected, (run.returncode, run.stdout, run.stderr)
    return json.loads(run.stdout) if run.stdout else None


def operation(patch, parents=(), actor=ACTOR_A, entity=TASK, kind='task', **kw):
    result = dict(schemaVersion=1, operationId=str(uuid.uuid4()), entityType=kind,
        entityId=entity, actorId=actor, parents=sorted(parents),
        createdAt='2026-10-23T12:00:00Z', source='poc', summary='Synthetic P0 activity', patch=patch)
    result.update(kw)
    return result


def incoming(tmp_path, op):
    folder = tmp_path/'incoming'; folder.mkdir(exist_ok=True)
    file = folder/(str(uuid.uuid4())+'.json')
    file.write_text(json.dumps(op))
    return file


def put(binary, directory, tmp_path, op, expected=0):
    return call(binary, 'import', directory, incoming(tmp_path, op), expected=expected)


def project(binary, directory):
    return call(binary, 'project', directory)


def test_offline_disjoint_fields_converge_and_keep_activities(metadata_cli, tmp_path):
    a, b = tmp_path/'replica-a', tmp_path/'replica-b'
    base = operation({'status':'todo', 'progress':0, 'archived':False, 'softDeleted':False})
    for d in [a, b]: put(metadata_cli, d, tmp_path, base)
    left = operation({'progress':50}, [base['operationId']])
    right = operation({'status':'waiting'}, [base['operationId']], actor=ACTOR_B,
                      createdAt='2020-01-01T00:00:00Z')  # clock skew must not discard a causal edit
    put(metadata_cli, a, tmp_path, left); put(metadata_cli, b, tmp_path, right)
    assert project(metadata_cli, a)['entities'][0]['values']['status'] == 'todo'
    for src, dst in [(b,a), (a,b)]:
        for file in src.glob('*.json'): shutil.copyfile(file, dst/file.name)
    pa, pb = project(metadata_cli,a), project(metadata_cli,b)
    assert pa == pb and pa['causallyCompleteAndConflictFree']
    assert pa['entities'][0]['values']['progress'] == 50
    assert pa['entities'][0]['values']['status'] == 'waiting'
    assert len(pa['entities'][0]['activityOperationIds']) == 3


def test_same_field_conflict_is_explicit_then_resolution_is_causal(metadata_cli,tmp_path):
    d=tmp_path/'replica'
    base=operation({'progress':0})
    left=operation({'progress':20},[base['operationId']])
    right=operation({'progress':70},[base['operationId']],actor=ACTOR_B)
    for op in [base,left,right]: put(metadata_cli,d,tmp_path,op)
    p=project(metadata_cli,d)
    assert not p['causallyCompleteAndConflictFree']
    assert 'progress' not in p['entities'][0]['values']
    assert {c['value'] for c in p['entities'][0]['conflicts']['progress']} == {20,70}
    # User-confirmed resolution sees both branches, rather than overwriting by timestamp.
    resolution=operation({'progress':60},[left['operationId'],right['operationId']])
    put(metadata_cli,d,tmp_path,resolution)
    p=project(metadata_cli,d)
    assert p['causallyCompleteAndConflictFree'] and p['entities'][0]['values']['progress']==60
    assert p['operationCount']==4


def test_delete_restore_preserves_concurrent_progress_and_history(metadata_cli,tmp_path):
    d=tmp_path/'replica'
    base=operation({'softDeleted':False,'progress':10,'status':'doing'})
    delete=operation({'softDeleted':True},[base['operationId']])
    edit=operation({'progress':80},[base['operationId']],actor=ACTOR_B)
    for op in [base,delete,edit]: put(metadata_cli,d,tmp_path,op)
    p=project(metadata_cli,d)
    assert p['entities'][0]['values']['softDeleted'] is True
    assert p['entities'][0]['values']['progress']==80
    restore=operation({'softDeleted':False},[delete['operationId'],edit['operationId']])
    put(metadata_cli,d,tmp_path,restore)
    p=project(metadata_cli,d)
    assert p['entities'][0]['values']['softDeleted'] is False and p['operationCount']==4
    assert len(p['operations'])==4 and p['entities'][0]['values']['status']=='doing'


def test_missing_parent_blocks_projection_then_recovers(metadata_cli,tmp_path):
    d=tmp_path/'replica'; base=operation({'status':'todo'})
    child=operation({'status':'done'},[base['operationId']])
    put(metadata_cli,d,tmp_path,child)
    p=project(metadata_cli,d)
    assert p['missingParents']==[base['operationId']] and not p['entities']
    assert not p['causallyCompleteAndConflictFree']
    put(metadata_cli,d,tmp_path,base)
    assert project(metadata_cli,d)['entities'][0]['values']['status']=='done'


def test_reordered_repeated_and_conflict_copy_delivery_is_idempotent(metadata_cli,tmp_path):
    base=operation({'status':'todo','progress':None})
    edits=[operation({'progress':n},[base['operationId']]) for n in [10,20,30]]
    ops=[base]+edits; snapshots=[]
    for n in range(4):
        d=tmp_path/f'replica-{n}'
        shuffled=ops[:]; random.Random(n).shuffle(shuffled)
        for op in shuffled: put(metadata_cli,d,tmp_path,op)
        assert put(metadata_cli,d,tmp_path,base)['added'] is False
        shutil.copyfile(d/(base['operationId']+'.json'),d/'duplicate-conflict-copy.json')
        snapshots.append(project(metadata_cli,d))
    assert all(p==snapshots[0] for p in snapshots)
    assert snapshots[0]['operationCount']==4


def test_uuid_reuse_never_overwrites_or_hides_different_content(metadata_cli,tmp_path):
    d=tmp_path/'replica'; base=operation({'status':'todo'})
    put(metadata_cli,d,tmp_path,base)
    changed=copy.deepcopy(base);changed['patch']['status']='done'
    put(metadata_cli,d,tmp_path,changed,expected=2)
    assert project(metadata_cli,d)['entities'][0]['values']['status']=='todo'
    (d/'untrusted-conflict-copy.json').write_text(json.dumps(changed))
    call(metadata_cli,'project',d,expected=2)


def test_concurrent_importers_publish_one_operation(metadata_cli,tmp_path):
    d=tmp_path/'replica';op=operation({'progress':10});file=incoming(tmp_path,op)
    def run(_): return call(metadata_cli,'import',d,file)
    with ThreadPoolExecutor(max_workers=8) as pool: results=list(pool.map(run,range(16)))
    assert sum(r['added'] for r in results)==1
    assert project(metadata_cli,d)['operationCount']==1


@pytest.mark.parametrize('barrier,code,count',[('before_publish',91,0),('after_publish',92,1)])
def test_actual_process_exit_at_publish_barrier(metadata_cli,tmp_path,barrier,code,count):
    d=tmp_path/'replica';op=operation({'progress':33});file=incoming(tmp_path,op)
    call(metadata_cli,'crash-import',d,file,barrier,expected=code)
    assert project(metadata_cli,d)['operationCount']==count
    # Retry the original logical operation, rather than generating a fresh operationId.
    call(metadata_cli,'import',d,file)
    assert project(metadata_cli,d)['operationCount']==1


@pytest.mark.parametrize('patch',[
    {'progress':True},{'progress':101},{'progress':-1},{'progress':1.5},
    {'status':'invented'},{'shell':'echo unsafe'},{'softDeleted':'yes'},
    {'groupId':'unknown'},{'archived':1},{}])
def test_invalid_business_patch_never_enters_journal(metadata_cli,tmp_path,patch):
    d=tmp_path/'replica';put(metadata_cli,d,tmp_path,operation(patch),expected=2)
    assert not list(d.glob('*.json'))


def test_nullable_progress_archiving_and_group_order_remain_distinct(metadata_cli,tmp_path):
    d=tmp_path/'replica'
    task=operation({'status':'waiting','progress':None,'archived':True,'softDeleted':False,'groupId':GROUP})
    group=operation({'sortOrder':2,'softDeleted':False},kind='group',entity=GROUP)
    for op in [task,group]:put(metadata_cli,d,tmp_path,op)
    p=project(metadata_cli,d)
    entities={e['entityType']:e['values'] for e in p['entities']}
    assert entities['task']['progress'] is None and entities['task']['archived'] is True
    assert entities['task']['softDeleted'] is False and entities['group']['sortOrder']==2


def test_parent_cycle_cannot_materialize(metadata_cli,tmp_path):
    a=operation({'status':'todo'});b=operation({'status':'doing'},[a['operationId']])
    a['parents']=[b['operationId']]
    for op in [a,b]:put(metadata_cli,tmp_path/'replica',tmp_path,op)
    call(metadata_cli,'project',tmp_path/'replica',expected=2)
