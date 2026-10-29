"""Argos model worker. One JSON request on stdin; JSON events on stdout.
No source text is sent over the network. Only explicit install uses HTTPS.
"""
import argparse
import hashlib
import contextlib
import json
import os
from pathlib import Path
import re
import shutil
import sys
import tempfile
import urllib.request
import urllib.error
import zipfile

PAIRS = {"en-zh": "https://argos-net.com/v1/translate-en_zh-1_9.argosmodel",
         "zh-en": "https://argos-net.com/v1/translate-zh_en-1_9.argosmodel"}


def emit(**data):
    print(json.dumps(data, ensure_ascii=True), flush=True)


def model_path(root, pair):
    path = root / pair
    return path if (path / "model/model.bin").is_file() and (path / "sentencepiece.model").is_file() else None


def install(root):
    root.mkdir(parents=True, exist_ok=True)
    for index, (pair, url) in enumerate(PAIRS.items()):
        if model_path(root, pair):
            continue
        with tempfile.TemporaryDirectory(prefix="install-", dir=root) as temp:
            temp = Path(temp)
            archive = temp / "model.zip"
            request = urllib.request.Request(url, headers={"User-Agent": "ScreenClip/1.1.2 (Argos model downloader)"})
            digest = hashlib.sha256()
            with urllib.request.urlopen(request, timeout=60) as response, archive.open("wb") as output:
                if not response.url.startswith("https://"):
                    raise ValueError("语言包下载需要 HTTPS")
                total = int(response.headers.get("Content-Length", 0))
                read = 0
                while chunk := response.read(1024 * 1024):
                    read += len(chunk)
                    if read > 512 * 1024 * 1024:
                        raise ValueError("语言包超出大小限制")
                    output.write(chunk)
                    digest.update(chunk)
                    emit(event="progress", message=f"正在下载{'英译中' if pair == 'en-zh' else '中译英'}语言包（{index+1}/2）",
                         progress=(index + (read / total if total else 0)) / 2)
            hashes = {"en-zh": "433e7c4f034d87fbe2353161e05f18646d7999452f801a4e1f0378522b9850ab",
                      "zh-en": "62e7af5a3a48b530e47b7b3e5c78c2de79073ecd815750d2bf3ab35b4a67da2d"}
            if digest.hexdigest() != hashes[pair]:
                raise ValueError("语言包校验失败，请重试")
            extract = temp / "unpacked"
            with zipfile.ZipFile(archive) as z:
                if sum(v.file_size for v in z.infolist()) > 1024**3:
                    raise ValueError("语言包解压大小超出限制")
                for item in z.infolist():
                    target = (extract / item.filename).resolve()
                    if not target.is_relative_to(extract.resolve()):
                        raise ValueError("语言包路径无效")
                z.extractall(extract)
            metadata = list(extract.rglob("metadata.json"))
            if len(metadata) != 1:
                raise ValueError("语言包元信息无效")
            source = metadata[0].parent
            data = json.loads(metadata[0].read_text(encoding="utf-8"))
            if f"{data['from_code']}-{data['to_code']}" != pair:
                raise ValueError("语言包方向不匹配")
            if not (source / "model/model.bin").is_file() or not (source / "sentencepiece.model").is_file():
                raise ValueError("语言包不完整")
            destination = root / pair
            if destination.exists() and not model_path(root, pair):
                if destination.resolve().parent != root.resolve():
                    raise ValueError("语言包目录无效")
                shutil.rmtree(destination)
            if not destination.exists():
                source.rename(destination)
    return {"ready": all(model_path(root, p) for p in PAIRS)}


def translate(root, request):
    import ctranslate2
    import sentencepiece
    source, target = request.get("from", "auto"), request.get("to")
    if target not in ("zh", "en") or source not in ("auto", "zh", "en"):
        raise ValueError("本地翻译目前支持简体中文与英文，请选择中英语言")
    texts = request.get("segments")
    segmented = texts is not None
    if not segmented:
        texts = [request.get("text", "")]
    if not isinstance(texts, list) or not texts or not all(isinstance(t, str) for t in texts) or sum(map(len, texts)) > 12000:
        raise ValueError("请输入 1–12,000 个字符的原文")
    models = {}
    def engine_for(pair):
        if pair not in models:
            path = model_path(root, pair)
            if not path:
                raise ValueError("请先在本地翻译设置中下载中英语言包")
            tokenizer = sentencepiece.SentencePieceProcessor(model_file=str(path / "sentencepiece.model"))
            engine = ctranslate2.Translator(str(path / "model"), device="cpu", compute_type="int8", intra_threads=2)
            models[pair] = (tokenizer, engine)
        return models[pair]
    outputs = []
    for text in texts:
        detected = source
        if source == "auto":
            if re.search(r"[\u3040-\u30ff\uac00-\ud7af\u0400-\u04ff]", text):
                raise ValueError("本地翻译目前只支持中英互译，请切换在线渠道")
            detected = "zh" if re.search(r"[\u3400-\u9fff]", text) else "en"
        if detected == target or not text.strip():
            outputs.append(text)
            continue
        tokenizer, engine = engine_for(f"{detected}-{target}")
        # Preserve newlines and blank lines. Bound sentence length to avoid
        # silently truncating long OCR lines at the decoder's token limit.
        pieces = re.split(r"(\r\n|\n|\r)", text)
        translated = []
        for line in pieces:
            if not line.strip() or line in ("\r\n", "\n", "\r"):
                translated.append(line)
                continue
            chunks = re.findall(r"[^。！？.!?]{1,240}[。！？.!?]*|[。！？.!?]+", line)
            result = []
            for chunk in chunks:
                tokens = tokenizer.encode(chunk, out_type=str)
                answer = engine.translate_batch([tokens], beam_size=4, max_decoding_length=1024)[0]
                if not answer.hypotheses or len(answer.hypotheses[0]) >= 1024:
                    raise ValueError("本地译文过长，请缩短文字后重试")
                result.append(tokenizer.decode(answer.hypotheses[0]).replace("▁", " ").strip())
            translated.append((' ' if target == 'en' else '').join(result))
        outputs.append(''.join(translated))
    return {"text": json.dumps(outputs, ensure_ascii=False) if segmented else outputs[0]}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--data-dir", required=True)
    args = parser.parse_args()
    root = Path(args.data_dir)
    request = json.loads(sys.stdin.buffer.read(256 * 1024))
    command = request.get("command")
    try:
        # Native inference libraries may log to stdout; reserve it for protocol.
        with contextlib.redirect_stdout(sys.stderr):
            if command == "status":
                data = {"ready": all(model_path(root, p) for p in PAIRS)}
            elif command == "translate":
                data = translate(root, request)
            elif command != "install":
                raise ValueError("不支持的本地翻译操作")
        if command == "install":
            data = install(root)
        emit(event="result", **data)
    except Exception as error:
        message = str(error) if isinstance(error, ValueError) else ("语言包下载失败，请检查网络后重试" if isinstance(error, (urllib.error.URLError, TimeoutError)) else "本地引擎运行失败，请检查语言包或重新准备")
        emit(event="error", message=message)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
