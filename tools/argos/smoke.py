"""Run on Windows x64, macOS arm64 and macOS x64, using a built helper.
Usage: python tools/argos/smoke.py --worker PATH --data-dir PATH [--download]
Writes only synthetic test fixtures to stdout; never user screenshots.
"""
import argparse
import json
import platform
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--worker', required=True)
parser.add_argument('--data-dir', required=True)
parser.add_argument('--download', action='store_true')
args = parser.parse_args()


def invoke(request):
    result = subprocess.run([args.worker, '--data-dir', args.data_dir], input=json.dumps(request),
                            text=True, encoding='utf-8', capture_output=True, timeout=1800)
    events = [json.loads(line) for line in result.stdout.splitlines()]
    final = events[-1]
    assert result.returncode == 0 and final['event'] == 'result', final
    return final


if args.download:
    assert invoke({'command': 'install'})['ready']
assert invoke({'command': 'status'})['ready']
outputs = []
for source, target, text in [('en', 'zh', 'Hello world!'), ('zh', 'en', '你好，世界！')]:
    result = invoke({'command': 'translate', 'text': text, 'from': source, 'to': target})['text']
    assert result.strip() and result != text
    outputs.append({'from': source, 'to': target, 'translation': result})
result = invoke({'command': 'translate', 'segments': ['Hello world!', '', 'Thank you.'], 'from': 'en', 'to': 'zh'})
segments = json.loads(result['text'])
assert len(segments) == 3 and segments[1] == '' and all(segments[i].strip() for i in (0,2))
print(json.dumps({'platform': platform.system(), 'architecture': platform.machine(), 'outputs': outputs, 'segments': segments}, ensure_ascii=True))
