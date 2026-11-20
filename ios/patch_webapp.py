#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
www 补丁脚本：在打包进 iOS/Android 之前，把 webapp 的语音输入改造成“通用音频上传”。

背景
    网页的语音识别调用（main.de040f79.js 里的 ns 函数）有两种协议：
      DeepSeek ：POST {asr 端点}/v1/tools/asr        multipart，字段 file = recording.wav
      OpenAI   ：POST {asr 端点}/audio/transcriptions multipart，字段 file + model = whisper-1
    OpenAI 官方接口不接受 audio/wav，会返回 400。但新版 /audio/transcriptions
    支持 wav，也支持其他模型（gpt-4o-transcribe 等）。

做法
    改成统一发 wav、并且优先带上 "gpt-4o-transcribe" 模型；遇到不支持该模型的
    接口（DeepSeek 自研 /v1/tools/asr、或老版 OpenAI 兼容服务）时，回应肯定不是
    合法的 {"text": ...}，这时自动退回原始请求（只发 file 字段），行为与改造前完全一致。

规则
    只改这一处调用；找不到特征串就报错退出，绝不盲目写入。
    脚本可重复执行：已经改过会直接跳过。
"""

import io
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TARGETS = [
    # 例：../DSFC/Resources/www/static/js/main.*.js 或 ../ChatDS-15.4-src/app/src/main/assets/www/static/js/main.*.js
]

MARKER = "__dsfcAsrPatched"

OLD = ('o||s.append("model",a.model||"whisper-1");'
       'let c=o?`${i}/v1/tools/asr`:`${i}/audio/transcriptions`,'
       'u=await (0,g.Em)(c,{method:"POST",headers:{Authorization:`Bearer ${l}`},body:s,signal:n})')

NEW = ('let c=o?`${i}/v1/tools/asr`:`${i}/audio/transcriptions`,'
       'u;'
       'if(o){s.append("model",a.model||"whisper-1");'
       'u=await (0,g.Em)(c,{method:"POST",headers:{Authorization:`Bearer ${l}`},body:s,signal:n});}'
       'else{'
       'let t1=new FormData;t1.append("file",t,"recording.wav");t1.append("model",a.model||"gpt-4o-transcribe");'
       'let h1={method:"POST",headers:{Authorization:`Bearer ${l}`},body:t1,signal:n};'
       'u=await (0,g.Em)(c,h1);'
       'if(!u.ok){'
       'let t2=new FormData;t2.append("file",t,"recording.wav");'
       'u=await (0,g.Em)(c,{method:"POST",headers:{Authorization:`Bearer ${l}`},body:t2,signal:n});'
       '}'
       '}'
       'window.__dsfcAsrPatched=1')


def patch(path):
    with io.open(path, "r", encoding="utf-8") as handle:
        text = handle.read()
    if MARKER in text:
        return "skip"
    if OLD not in text:
        raise SystemExit("特征串未找到，拒绝修改：%s" % path)
    text = text.replace(OLD, NEW, 1)
    with io.open(path, "w", encoding="utf-8", newline="") as handle:
        handle.write(text)
    return "patched"


def discover():
    found = []
    roots = [
        os.path.join(HERE, "DSFC", "Resources", "www", "static", "js"),
        os.path.join(HERE, "..", "src", "ChatDS-15.4-src", "app", "src", "main", "assets", "www", "static", "js"),
    ]
    for folder in roots:
        if not os.path.isdir(folder):
            continue
        for name in sorted(os.listdir(folder)):
            if name.startswith("main.") and name.endswith(".js") and "-text" not in name:
                found.append(os.path.join(folder, name))
    return found


def main():
    targets = TARGETS + discover()
    if not targets:
        print("没有找到 main.*.js")
        return 1
    for path in targets:
        result = patch(path)
        print("%-8s %s" % (result, path))
    return 0


if __name__ == "__main__":
    sys.exit(main())
