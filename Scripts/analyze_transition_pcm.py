#!/usr/bin/env python3
"""Validate saved production PCM and create listening/plot artifacts.

Usage: python3 Scripts/analyze_transition_pcm.py .noindex/artifacts/pcm-transition
Requires numpy and matplotlib. Set MPLCONFIGDIR to the project's .noindex/tmp.
Float32 originals are preserved; listening WAVs are PCM16 copies, without gain
normalization. Input paths and verification metadata come from the capture tests.
"""
import argparse
import html
import json
import struct
import wave
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np


def read_float_wav(path):
    raw = path.read_bytes()
    assert raw[:4] == b"RIFF" and raw[8:12] == b"WAVE", path
    pos, fmt, data = 12, None, None
    while pos + 8 <= len(raw):
        tag, size = struct.unpack_from("<4sI", raw, pos)
        block = raw[pos + 8:pos + 8 + size]
        assert len(block) == size
        if tag == b"fmt ":
            fmt = struct.unpack_from("<HHIIHH", block)
        elif tag == b"data":
            data = block
        pos += 8 + size + size % 2
    assert fmt and data is not None
    encoding, channels, rate, _, alignment, bits = fmt
    assert encoding == 3 and bits == 32 and alignment == channels * 4, fmt
    return np.frombuffer(data, dtype="<f4").reshape(-1, channels).astype(np.float64), rate


def listening_wav(path, samples, rate):
    assert np.max(np.abs(samples)) <= 1
    pcm = np.rint(samples * 32767).astype("<i2")
    with wave.open(str(path), "wb") as out:
        out.setnchannels(samples.shape[1]); out.setsampwidth(2)
        out.setframerate(rate); out.writeframes(pcm.tobytes())


def rms(samples, rate, seconds=0.02):
    n = round(seconds * rate)
    count = len(samples) // n
    values = np.sqrt(np.mean(samples[:count * n].reshape(count, n, -1) ** 2, axis=(1, 2)))
    return (np.arange(count) + 0.5) * n / rate, values


def carrier(samples, rate, frequency):
    n, hop = round(rate * 0.05), round(rate * 0.01)
    blocks = np.lib.stride_tricks.sliding_window_view(samples[:, 0], n)[::hop]
    phase = np.exp(-2j * np.pi * frequency * np.arange(n) / rate)
    amplitude = np.abs(blocks @ phase) * 2 / n
    times = (np.arange(len(amplitude)) * hop + n / 2) / rate
    candidates = np.flatnonzero((amplitude[1:-1] > amplitude[:-2]) &
        (amplitude[1:-1] >= amplitude[2:]) & (amplitude[1:-1] > amplitude.max() * 0.35)) + 1
    peaks = []
    for i in candidates:
        if not peaks or times[i] - peaks[-1] > 0.18:
            peaks.append(float(times[i]))
    return times, amplitude, np.array(peaks)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    args = parser.parse_args()
    root = args.root.resolve()
    names = ["fixed", "smart-beats", "smart-energy", "smart-levels"]
    labels = ["Fixed (same cap)", "Smart / reliable beat grid", "Smart / different tempos", "Smart / 14 dB level difference"]
    fig, axes = plt.subplots(4, 1, figsize=(11, 10), constrained_layout=True)
    summaries, rows = [], []
    beat_plot = None
    for name, label, ax in zip(names, labels, axes):
        folder = root / "scenarios" / name
        meta = json.loads((folder / "validation.json").read_text())
        recording = json.loads((folder / "recording.json").read_text())
        mix, rate = read_float_wav(folder / "transition-mix.wav")
        output, output_rate = read_float_wav(folder / "output.wav")
        assert rate == output_rate == 48000 and mix.shape[1] == output.shape[1] == 2
        assert len(mix) == meta["mixFrames"] and len(output) == meta["outputFrames"]
        for key, pcm in [("transitionMix", mix), ("output", output)]:
            report = recording[key]
            assert report["receivedFrames"] == report["writtenFrames"] == len(pcm)
            assert report["droppedFrames"] == report["rejectedFrames"] == 0
            assert "writeError" not in report or report["writeError"] is None
            assert np.isfinite(pcm).all() and np.max(np.abs(pcm)) <= 1
        assert not recording["endedByGraphChange"]
        count = min(len(mix), len(output))
        gain_error = float(np.linalg.norm(output[:count] - mix[:count] * 0.5) / np.linalg.norm(mix[:count] * 0.5))
        assert gain_error < 1e-5
        start, end = meta["commitFrame"] / rate, meta["retirementFrame"] / rate
        assert abs(end - start - meta["selectedOverlapSeconds"]) < 1 / rate
        ta, aa, pa = carrier(mix, rate, 440)
        tb, ab, pb = carrier(mix, rate, 660)
        # Carriers independently expose source tempo after the real resampler.
        clean_a, clean_b = pa[pa < start - 0.1], pb[pb > end + 0.1]
        a_period = float(np.median(np.diff(clean_a)))
        b_period = float(np.median(np.diff(clean_b)))
        expected_b = 0.7 if name in ["smart-energy", "smart-levels"] else 0.5
        assert abs(a_period - 0.5) <= 0.011 and abs(b_period - expected_b) <= 0.011
        beat_offset = None
        if name == "smart-beats":
            middle = pb[(pb > start + 1) & (pb < end - 1)]
            assert len(middle) >= 3
            beat_offset = float(max(min(abs(pa - peak)) for peak in middle))
            assert beat_offset <= 0.02
            beat_plot = (ta, aa, tb, ab, pa, pb, start, end)
        audible = np.flatnonzero(np.max(np.abs(output), axis=1) > 0.0001)
        assert audible.size and audible[0] / rate <= 0.025
        signal_end = (audible[-1] + 1) / rate
        # 20 ms edge guards remain on each track; actual playback clocks, not
        # the capture callback count, determine the natural content duration.
        expected_content = 2 * meta["sourceAudibleSeconds"] - (end - start)
        assert abs(signal_end - (expected_content - 0.02)) < 0.015
        listening_wav(folder / "listen.wav", output, rate)
        listening_wav(folder / "transition-listen.wav", output[max(0, round((start - 2) * rate)):round((end + 3) * rate)], rate)
        t, level = rms(mix, rate)
        ax.plot(t, level, color="#3454a1", linewidth=0.9, label="Transition mix RMS")
        to, lo = rms(output, rate)
        ax.plot(to, lo, color="#c16828", linewidth=0.7, alpha=0.7, label="Final output RMS (volume 0.5)")
        ax.axvspan(start, end, color="#3ba78d", alpha=0.15)
        ax.axvline(start, color="#338e77", linestyle="--", linewidth=0.8)
        ax.axvline(end, color="#338e77", linestyle="--", linewidth=0.8)
        ax.set(title=f"{label} — overlap {end - start:.3f} s", ylabel="RMS", xlim=(0, 26))
        ax.grid(alpha=0.18)
        summary = {**meta, "independentGainError": gain_error, "measuredAPeriodSeconds": a_period,
            "measuredBPeriodSeconds": b_period, "measuredBeatOffsetSeconds": beat_offset,
            "capturedOutputSeconds": len(output) / rate, "audibleEndSeconds": signal_end,
            "callbackPullAheadFrames": len(mix) - len(output), "peakAllChannels": float(np.max(np.abs(mix))),
            "clippedSamples": int(np.count_nonzero(np.abs(mix) >= 1)), "passed": True}
        summaries.append(summary)
        base = f"scenarios/{name}"
        rows.append(f'<article><h2>{html.escape(label)}</h2><p>过渡 {end-start:.3f} 秒 · 原速 · 丢帧 0 · 削波 0</p>'
            f'<p>过渡片段</p><audio controls preload="none" src="{base}/transition-listen.wav"></audio>'
            f'<p>完整输出</p><audio controls preload="none" src="{base}/listen.wav"></audio>'
            f'<p><a href="{base}/transition-mix.wav">混音 PCM Float32</a> · <a href="{base}/output.wav">最终输出 PCM Float32</a>'
            f' · <a href="{base}/validation.json">流程帧记录</a></p></article>')
    axes[0].legend(loc="upper right", fontsize=8)
    axes[-1].set_xlabel("Actual render timeline (seconds)")
    fig.savefig(root / "rms-comparison.png", dpi=160)
    plt.close(fig)
    ta, aa, tb, ab, pa, pb, start, end = beat_plot
    fig, ax = plt.subplots(figsize=(11, 3.8), constrained_layout=True)
    ax.plot(ta, aa, label="A / 440 Hz amplitude", color="#3454a1")
    ax.plot(tb, ab, label="B / 660 Hz amplitude", color="#c16828")
    ax.axvspan(start, end, color="#3ba78d", alpha=0.1)
    ax.set(xlim=(start + 0.9, end - 0.9), xlabel="Actual render timeline (seconds)", ylabel="Carrier amplitude",
        title="Measured percussion peaks in saved smart mix (50 ms analysis windows)")
    ax.grid(alpha=0.18); ax.legend()
    fig.savefig(root / "beat-alignment.png", dpi=160); plt.close(fig)
    (root / "analysis.json").write_text(json.dumps({"scenarios": summaries, "allPassed": True}, indent=2) + "\n")
    page = '<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
    page += '<title>智能渐变 PCM 验证</title><style>body{font:16px system-ui;max-width:1000px;margin:40px auto;padding:0 20px;color:#20242b;background:#fafaf8}h1{font-size:30px}h2{font-size:21px}article{padding:20px 0;border-bottom:1px solid #ccc}audio{width:100%}img{width:100%;background:white}p{line-height:1.6}a{color:#3454a1}</style>'
    page += '<h1>智能渐变 · 实际 PCM 验证</h1><p>FFmpeg 解码 → 双路过渡混音 → EQ / 效果链 → 总音量 → AVAudioEngine 输出。两处存储节点保存 Float32 WAV。试听文件仅转为 PCM16，没有响度归一化；总音量设为 0.5。</p>'
    page += '<p>A：440 / 880 Hz，120 BPM；B：660 / 1320 Hz，120 或约 86 BPM。每首 14 秒，头部静音 0.4 秒、尾部静音 0.6 秒。音量差场景约 14 dB。四组均使用相同 12 秒上限和首尾静音跳过。</p>'
    page += '<p>检查通过：保存帧数、格式、无丢帧、无削波、原速节拍、静音边界和输出增益。录下的同节拍过渡拍点差 ≤20 ms。听感仍需人工试听；结果不代表真实歌曲或真机路由验收。</p>'
    page += '<img src="rms-comparison.png" alt="Four saved PCM RMS traces"><img src="beat-alignment.png" alt="Saved PCM percussion peak alignment">'
    page += ''.join(rows)
    page += '<p>源节点因音频引擎预拉取而比最终输出多保存一部分回调帧；末尾零帧保留在原始证据中，不计作歌曲时长。实时 tap 可能不交付末尾不足一块的数据，精确输出验收使用 offline render blocks。</p><p><a href="analysis.json">独立音频分析 JSON</a></p></html>'
    (root / "index.html").write_text(page)
    print(json.dumps({"allPassed": True, "scenarios": [{"scenario": s["scenario"], "overlap": s["selectedOverlapSeconds"], "beatOffset": s["measuredBeatOffsetSeconds"], "gainError": s["independentGainError"]} for s in summaries]}, indent=2))


if __name__ == "__main__":
    main()
