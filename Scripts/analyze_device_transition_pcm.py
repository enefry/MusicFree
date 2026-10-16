#!/usr/bin/env python3
"""Independently read physical-device PCM; never infer sound from UI state.

Usage: MPLCONFIGDIR=.noindex/tmp/matplotlib python3 Scripts/analyze_device_transition_pcm.py ROOT
The original Float32 files are preserved. Listen copies only change bit depth.
"""
import argparse
import html
import json
from pathlib import Path

import numpy as np

from analyze_transition_pcm import carrier, listening_wav, read_float_wav, rms
import matplotlib.pyplot as plt


SCENARIOS = ["fixed-12", "fixed-short", "fixed-min", "smart-beats", "smart-energy", "smart-levels",
             "gapless-skip", "gapless-raw", "gapless-mixed", "middle-silence", "fade-in", "fade-out",
             "fades-both", "effects-off"]


def amplitude(pcm, rate, frequency, time):
    n = round(rate * 0.05)
    start = round(time * rate) - n // 2
    x = pcm[start:start + n, 0]
    assert len(x) == n
    return float(abs(x @ np.exp(-2j * np.pi * frequency * np.arange(n) / rate)) * 2 / n)


def output_delay(mix, output, rate, gain):
    n = min(rate, len(mix), len(output) - round(rate * 0.2))
    assert n > 0
    def error(lag):
        return np.mean((output[lag:lag + n, 0] - mix[:n, 0] * gain) ** 2)
    coarse = min(range(0, round(rate * 0.2), 64), key=error)
    return min(range(max(0, coarse - 63), coarse + 64), key=error)


def validate_folder(folder):
    meta = json.loads((folder / "validation.json").read_text())
    report = json.loads((folder / "recording.json").read_text())
    assert meta["physicalDevice"] and not meta["manualRendering"]
    assert report["outputDelivery"] == "realtime-tap-blocks"
    mix, rate = read_float_wav(folder / "transition-mix.wav")
    output, output_rate = read_float_wav(folder / "output.wav")
    assert rate == output_rate == 48000
    for key, pcm in [("transitionMix", mix), ("output", output)]:
        node = report[key]
        assert node["receivedFrames"] == node["writtenFrames"] == len(pcm)
        assert node["droppedFrames"] == node["rejectedFrames"] == 0 and not node.get("writeError")
        assert np.isfinite(pcm).all() and np.max(np.abs(pcm)) < 1
    gain = meta["outputGain"]
    lag = output_delay(mix, output, rate, gain)
    count = min(len(mix), len(output) - lag)
    # A pause can discard a withheld partial tap block, and seek deliberately
    # closes the capture. Those sessions have discontinuous capture clocks;
    # compare the uninterrupted prefix rather than forcing one global offset.
    if folder.name == "transport":
        count = min(count, rate * 3)
    reference = mix[:count] * gain
    error = float(np.linalg.norm(output[lag:lag + count] - reference) / np.linalg.norm(reference))
    assert error < 1e-5, (folder.name, lag, error)
    active_mix = np.flatnonzero(np.max(np.abs(mix), axis=1) > 0.0001)
    active_output = np.flatnonzero(np.max(np.abs(output), axis=1) > 0.000025)
    assert active_mix.size and active_output.size
    # Different thresholds cancel the master gain, so the same audible tail
    # must be present after compensating measured pipeline latency.
    mix_end, output_end = int(active_mix[-1] + 1), int(active_output[-1] + 1)
    tail_gap = max(0, mix_end + lag - output_end) / rate
    if not report["endedByGraphChange"]:
        assert tail_gap < 0.002, (folder.name, "missing audible tail", tail_gap)
    summary = {**meta, "measuredPipelineDelaySeconds": lag / rate, "independentGainRelativeRMSError": error,
               "audibleTailCoverageGapSeconds": tail_gap, "outputTrailingSilenceSeconds": (len(output) - output_end) / rate,
               "clippedSamples": int(np.count_nonzero(np.abs(output) >= 1)), "passed": True}
    summary["gainComparisonSeconds"] = count / rate
    summary["endedByGraphChange"] = report["endedByGraphChange"]
    if folder.name in SCENARIOS:
        assert not report["endedByGraphChange"]
        assert len(mix) == meta["mixFrames"] and len(output) == meta["outputFrames"]
    if meta.get("commits"):
        start, end = meta["commitFrame"] / rate, meta["retirementFrame"] / rate
        assert abs(end - start - meta["selectedOverlapSeconds"]) <= 1 / rate
        ta, aa, pa = carrier(mix, rate, 440)
        tb, ab, pb = carrier(mix, rate, 660)
        clean_a, clean_b = pa[pa < start - 0.1], pb[pb > end + 0.1]
        if len(clean_a) >= 3:
            period = float(np.median(np.diff(clean_a)))
            assert abs(period - 0.5) <= 0.011
            summary["measuredAPeriodSeconds"] = period
        if len(clean_b) >= 3:
            period = float(np.median(np.diff(clean_b)))
            assert abs(period - (0.7 if folder.name in ["smart-energy", "smart-levels"] else 0.5)) <= 0.011
            summary["measuredBPeriodSeconds"] = period
        if folder.name == "smart-beats":
            middle = pb[(pb > start + 1) & (pb < end - 1)]
            assert len(middle) >= 3
            offset = float(max(min(abs(pa - peak)) for peak in middle))
            assert offset <= 0.02
            summary["maximumMeasuredBeatOffsetSeconds"] = offset
        if folder.name == "gapless-skip":
            # The two 20 ms edge guards remain; there must be no additional gap.
            a = mix[round((start - 0.08) * rate):round((start + 0.08) * rate)]
            t, level = rms(a, rate, 0.005)
            assert np.count_nonzero(level < 0.001) <= 9
            summary["handoffLowLevelSeconds"] = float(np.count_nonzero(level < 0.001) * 0.005)
        if folder.name == "middle-silence":
            quiet = mix[round(1.14 * rate):round(1.70 * rate)]
            assert np.max(np.abs(quiet)) < 0.0001
            assert np.sqrt(np.mean(mix[round(1.0 * rate):round(1.1 * rate)] ** 2)) > 0.01
            assert np.sqrt(np.mean(mix[round(1.8 * rate):round(1.9 * rate)] ** 2)) > 0.01
            summary["preservedMiddleSilenceSeconds"] = 0.6
    if folder.name in ["fade-in", "fade-out", "fades-both", "effects-off"]:
        checks = []
        if meta["fadeInSeconds"]:
            for time in [0.5, 1.5, 2.7]:
                measured = amplitude(mix, rate, 440, time) / 0.2
                expected = time / 3
                assert abs(measured - expected) < 0.01
                checks.append({"time": time, "measuredGain": measured, "expectedGain": expected})
        if meta["fadeOutSeconds"]:
            beginning = meta["sourceDuration"] - 3
            for offset in [0.5, 1.5, 2.7]:
                measured = amplitude(mix, rate, 440, beginning + offset) / 0.2
                expected = (1000 ** (1 - offset / 3) - 1) / 999
                assert abs(measured - expected) < 0.01
                checks.append({"time": beginning + offset, "measuredGain": measured, "expectedGain": expected})
        if folder.name == "effects-off":
            assert abs(amplitude(mix, rate, 440, 0.5) / 0.2 - 1) < 0.01
            assert abs(amplitude(mix, rate, 440, 3.5) / 0.2 - 1) < 0.01
        summary["envelopeMeasurements"] = checks
    listening_wav(folder / "listen.wav", output, rate)
    if "commitFrame" in meta:
        begin = max(0, round(meta["commitFrame"] + lag - 2 * rate))
        end = min(len(output), round(meta["retirementFrame"] + lag + 2 * rate))
        listening_wav(folder / "transition-listen.wav", output[begin:end], rate)
    return summary, mix, output, rate


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    args = parser.parse_args()
    root = args.root.resolve()
    summaries, rows = [], []
    fig, axes = plt.subplots(6, 1, figsize=(11, 12), constrained_layout=True)
    plot_names = ["fixed-12", "smart-beats", "smart-energy", "smart-levels", "gapless-skip", "fades-both"]
    for name in SCENARIOS + ["transport", "transport-stop", "natural-tail"]:
        summary, mix, output, rate = validate_folder(root / name)
        summaries.append(summary)
        if name in plot_names:
            ax = axes[plot_names.index(name)]
            t, level = rms(mix, rate)
            ax.plot(t, level, color="#3454a1", label="Transition mix")
            t, level = rms(output, rate)
            ax.plot(t, level, color="#c16828", label="Before system output")
            if "commitFrame" in summary:
                ax.axvspan(summary["commitFrame"] / rate, summary["retirementFrame"] / rate, color="#3ba78d", alpha=0.15)
            ax.set(title=name, ylabel="RMS"); ax.grid(alpha=0.2)
        label = html.escape(name)
        overlap = summary.get("selectedOverlapSeconds")
        detail = f" · 重叠 {overlap:.3f} 秒" if overlap is not None else ""
        audio = "transition-listen.wav" if overlap is not None else "listen.wav"
        rows.append(f'<article><h2>{label}</h2><p>PCM 验证通过{detail} · 写盘丢帧 0 · 削波 0</p>'
                    f'<audio controls preload="none" src="{name}/{audio}"></audio>'
                    f'<p><a href="{name}/output.wav">系统输出前 PCM</a> · <a href="{name}/transition-mix.wav">过渡混音 PCM</a>'
                    f' · <a href="{name}/validation.json">真机路线和时序</a></p></article>')
    residual, _ = read_float_wav(root / "natural-tail" / "residual.wav")
    assert np.max(np.abs(residual)) < 0.0001
    no_record = json.loads((root / "natural-tail-no-recording" / "validation.json").read_text())
    residual, _ = read_float_wav(root / "natural-tail-no-recording" / "residual.wav")
    assert no_record["physicalDevice"] and len(residual) == no_record["residualFrames"] > 4800
    assert np.max(np.abs(residual)) < 0.0001 and no_record["residualPeak"] < 0.0001
    replacement = json.loads((root / "replace-during-drain" / "validation.json").read_text())
    assert replacement["physicalDevice"] and replacement["replacementStillPlaying"]
    axes[0].legend(); axes[-1].set_xlabel("Recorded timeline (seconds)")
    fig.savefig(root / "comparison.png", dpi=150); plt.close(fig)
    (root / "analysis.json").write_text(json.dumps({"allPassed": True, "scenarios": summaries,
        "additionalChecks": [no_record, replacement]}, indent=2) + "\n")
    page = '<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>iPhone 12 过渡验证</title>'
    page += '<style>body{font:16px system-ui;max-width:1000px;margin:32px auto;padding:0 20px;background:#fafaf8;color:#20242b}article{border-top:1px solid #ccc;padding:16px 0}audio,img{width:100%}p{line-height:1.6}a{color:#3454a1}</style>'
    page += '<h1>iPhone 12 Pro · 实时过渡 PCM</h1><p>iOS 17.6.1，内置扬声器，48 kHz。真实 FFmpeg 解码与 AVAudioEngine 实时渲染；系统输出前主混音器 PCM 包含应用音量 0.25，系统媒体音量在此之后生效。</p>'
    page += '<p>测得下游延迟约 85.33 ms，对齐后比较两个节点；试听副本仅转换到 PCM16，没有归一化。内部 PCM 验证不等同于外部麦克风回录或主观听感验收。</p><img src="comparison.png" alt="Device PCM comparisons">'
    page += ''.join(rows) + '<p><a href="analysis.json">独立分析结果</a></p></html>'
    (root / "index.html").write_text(page)
    print(json.dumps({"allPassed": True, "scenarios": [{"scenario": s["scenario"], "overlap": s.get("selectedOverlapSeconds"),
          "delay": s["measuredPipelineDelaySeconds"], "gainError": s["independentGainRelativeRMSError"],
          "tailGap": s["audibleTailCoverageGapSeconds"]} for s in summaries]}, indent=2))


if __name__ == "__main__":
    main()
