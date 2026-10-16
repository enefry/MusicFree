#!/usr/bin/env python3
"""Measure saved beat-matching PCM, including real-time device output.

Usage: MPLCONFIGDIR=.noindex/tmp/matplotlib python3 Scripts/analyze_beat_matching_pcm.py ROOT
Requires numpy and matplotlib. Float32 originals remain unchanged.
"""
import argparse
import html
import json
from pathlib import Path

import numpy as np
from analyze_transition_pcm import read_float_wav, listening_wav
from analyze_device_transition_pcm import output_delay
import matplotlib.pyplot as plt


def carrier_envelope(samples, rate, frequency):
    size, hop = round(rate * 0.02), round(rate * 0.005)
    blocks = np.lib.stride_tricks.sliding_window_view(samples, size)[::hop]
    # Both carriers share each physical-device channel. A tapered window
    # suppresses leakage from A's pulses into B's envelope (and vice versa).
    window = np.hanning(size)
    phase = np.exp(-2j * np.pi * frequency * np.arange(size) / rate) * window
    levels = np.abs(blocks @ phase) * 2 / window.sum()
    times = (np.arange(len(levels)) * hop + size / 2) / rate
    beats = []
    # The fixtures contain 30–40 ms pulses; compare against the preceding
    # baseline so a flat pulse top remains detectable after windowing.
    for i in range(8, len(levels) - 1):
        if (levels[i] > 0.012 and levels[i] > levels[i - 1] and levels[i] >= levels[i + 1]
                and levels[i] - levels[i - 8] > max(0.006, levels[i] * 0.5)):
            # Locate the half-height rising edge, rather than a phase-dependent
            # maximum anywhere along a flat pulse top. Interpolate the 5 ms grid.
            baseline = levels[max(0, i - 16):i + 1].min()
            threshold = (baseline + levels[i]) / 2
            onset = i
            while onset > 0 and levels[onset - 1] > threshold:
                onset -= 1
            fraction = (threshold - levels[onset - 1]) / (levels[onset] - levels[onset - 1]) if onset else 0
            beat = float(times[max(0, onset - 1)] + fraction * hop / rate)
            if not beats or beat - beats[-1] >= 0.2:
                beats.append(beat)
    return times, levels, np.asarray(beats)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    root = parser.parse_args().root.resolve()
    folders = sorted(p.parent for p in root.glob("*/validation.json") if "transport" not in p.parent.name)
    assert folders, "No captured scenes"
    fig, axes = plt.subplots(len(folders), 2, figsize=(13, 3.3 * len(folders)), squeeze=False, constrained_layout=True)
    summaries, rows = [], []
    for folder, (left, right) in zip(folders, axes):
        meta = json.loads((folder / "validation.json").read_text())
        recording = json.loads((folder / "recording.json").read_text())
        physical = meta.get("physicalDevice", False)
        if physical:
            assert not meta["manualRendering"]
            assert recording["outputDelivery"] == "realtime-tap-blocks"
        mix, rate = read_float_wav(folder / "transition-mix.wav")
        output, output_rate = read_float_wav(folder / "output.wav")
        assert rate == output_rate == 48000
        assert not recording["endedByGraphChange"]
        for key, pcm in [("transitionMix", mix), ("output", output)]:
            node = recording[key]
            assert node["receivedFrames"] == node["writtenFrames"] == len(pcm)
            assert node["droppedFrames"] == node["rejectedFrames"] == 0 and not node.get("writeError")
            assert np.isfinite(pcm).all() and np.max(np.abs(pcm)) < 1
        gain = meta.get("outputGain", 0.5)
        delay = output_delay(mix, output, rate, gain) if physical else 0
        count = min(len(mix), len(output) - delay)
        gain_error = float(np.linalg.norm(output[delay:delay + count] - mix[:count] * gain) / np.linalg.norm(mix[:count] * gain))
        assert gain_error < 1e-5, (folder.name, gain_error)
        start = meta["commitFrame"] / rate if physical else meta["handoffSeconds"]
        end = meta["retirementFrame"] / rate if physical else meta["retirementSeconds"]
        recovery = meta["recoverySeconds"]
        ratio = meta["incomingRate"]
        period = meta.get("inputPeriod", 0.52 if "faster" in folder.name else 0.48)
        ta, aa, pa = carrier_envelope(mix[:, 0], rate, 440)
        tb, ab, pb = carrier_envelope(mix[:, 0 if physical else 1], rate, 660)
        measured = pb[(pb > start + 0.7) & (pb < end - 0.5)]
        offsets = np.array([min(abs(pa - t)) for t in measured])
        beat_error = float(offsets.max()) if len(offsets) else None
        if meta["basis"] == "beats":
            assert len(measured) >= 4 and beat_error <= 0.025, (folder.name, beat_error, measured)
        restored = pb[(pb > end + recovery + 0.5) & (pb < len(mix) / rate - 0.5)]
        intervals = np.diff(restored)
        assert len(intervals) >= 5 and np.max(abs(intervals - period)) <= 0.015, (folder.name, intervals)
        restored_period = float(np.polyfit(np.arange(len(restored)), restored, 1)[0])
        assert abs(restored_period - period) < 0.002, (folder.name, restored_period)
        recovery_peaks = pb[(pb > start + 0.7) & (pb < end + recovery + 0.5)]
        recovery_intervals = np.diff(recovery_peaks)
        assert len(recovery_intervals) >= 4
        assert np.all(recovery_intervals >= min(period, period / ratio) - 0.02)
        assert np.all(recovery_intervals <= max(period, period / ratio) + 0.02), (folder.name, recovery_intervals)
        # FFT measures the carrier independently of the schedule and beat detector.
        begin = round((start + 1) * rate)
        signal = mix[begin:begin + rate, 0 if physical else 1]
        spectrum = np.abs(np.fft.rfft(signal * np.hanning(len(signal))))
        pitch = float(640 + np.argmax(spectrum[640:681]))
        assert abs(pitch - 660) <= 2, (folder.name, pitch)
        active_mix = np.flatnonzero(np.max(abs(mix), axis=1) > 0.0001)
        active_output = np.flatnonzero(np.max(abs(output), axis=1) > 0.0001 * gain)
        tail_gap = max(0, int(active_mix[-1]) + delay - int(active_output[-1])) / rate
        assert tail_gap < 0.002, (folder.name, tail_gap)
        summary = {"scenario": folder.name, "physicalDevice": physical, "passed": True, "basis": meta["basis"],
            "incomingRate": ratio, "overlapSeconds": end - start, "recoverySeconds": recovery,
            "maximumBeatOffsetSeconds": beat_error, "restoredPeriodSeconds": restored_period,
            "recoveryMinimumBeatIntervalSeconds": float(recovery_intervals.min()),
            "recoveryMaximumBeatIntervalSeconds": float(recovery_intervals.max()),
            "carrierPitchHz": pitch, "outputDelayFrames": delay, "gainRelativeRMSError": gain_error,
            "audibleTailGapSeconds": tail_gap, "nonfiniteSamples": 0, "clippedSamples": 0, "droppedFrames": 0}
        summaries.append(summary)
        left.plot(ta, aa, label="A / 440 Hz", lw=1)
        left.plot(tb, ab, label="B / 660 Hz", lw=1)
        for t in pa: left.axvline(t, color="C0", alpha=0.15, lw=0.5)
        for t in pb: left.axvline(t, color="C1", alpha=0.15, lw=0.5)
        left.set(xlim=(start + 0.4, end - 0.2), title=f"{folder.name}: overlap beats", xlabel="Output time (s)", ylabel="Carrier amplitude")
        left.legend(fontsize=8)
        right.plot(pb[1:], np.diff(pb), ".-", label="Measured B beat interval")
        right.axhline(period, color="C2", ls="--", label="Original interval")
        if ratio != 1: right.axhline(period / ratio, color="C3", ls=":", label="Matched interval")
        right.axvspan(start, end, color="C0", alpha=0.08, label="Overlap")
        right.axvspan(end, end + recovery, color="C2", alpha=0.08, label="Recovery")
        right.set(xlim=(start, min(len(mix) / rate - 0.5, end + recovery + 4)), ylim=(0.43, 0.76),
            title="Return to original tempo" if meta["basis"] == "beats" else "Original tempo (energy fallback)",
            xlabel="Output time (s)", ylabel="Beat interval (s)")
        right.legend(fontsize=7)
        listening_wav(folder / "listen-output.wav", output, rate)
        listening_wav(folder / "listen-mix.wav", mix, rate)
        label = html.escape(folder.name)
        alignment = f"beat error {beat_error:.3f}s" if meta["basis"] == "beats" else "energy fallback, original speed"
        rows.append(f'<section><h2>{label}</h2><p>Incoming rate {ratio:.3f}×; overlap {end-start:.3f}s; recovery {recovery:.3f}s; {alignment}.</p><p>Output before system volume</p><audio controls preload="none" src="{label}/listen-output.wav"></audio><p>Transition mix</p><audio controls preload="none" src="{label}/listen-mix.wav"></audio></section>')
    fig.savefig(root / "comparison.png", dpi=150)
    plt.close(fig)
    (root / "analysis.json").write_text(json.dumps(summaries, indent=2))
    (root / "index.html").write_text('<!doctype html><meta charset="utf-8"><title>Beat matching PCM verification</title><style>body{max-width:1120px;margin:32px auto;font:16px system-ui;padding:0 20px;line-height:1.5}img{width:100%}audio{width:100%}section{border-top:1px solid #ddd;padding:20px 0}</style><h1>Beat matching PCM verification</h1><p>Generated fixtures through FFmpeg decoding, independent per-track time stretching, transition mixing and final output. Listening copies preserve level. These measurements do not establish subjective quality for real music.</p><img src="comparison.png" alt="Measured beat alignment and tempo recovery">' + ''.join(rows))
    print(json.dumps(summaries, indent=2))


if __name__ == "__main__":
    main()
