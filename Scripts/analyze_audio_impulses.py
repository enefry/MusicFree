#!/usr/bin/env python3
"""Full-track spectral evidence and optional conservative offline de-click trial.

Requires ffmpeg/ffprobe, NumPy, SciPy, Matplotlib. Never modifies the input.
The detector's candidates are NOT a count of confirmed audible defects.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

import numpy as np
from scipy import signal


def run(*args: str, data: bytes | None = None) -> subprocess.CompletedProcess:
    return subprocess.run(args, input=data, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, check=True)


def db(value):
    return 20 * np.log10(np.maximum(value, 1e-15))


def repair_impulses(audio: np.ndarray, rate: int, threshold: float = 6):
    if not np.isfinite(threshold) or not 1 <= threshold <= 100:
        raise ValueError("De-click threshold must be finite and between 1 and 100")
    # FFmpeg's overlap-add startup attenuates ~41 ms without context. Add
    # 100 ms odd-reflection guards, then remove them by exact sample count.
    # Odd reflection preserves the edge slope of smooth tonal material.
    guard = max(1, round(rate * .1))
    extended = np.pad(audio, ((guard, guard), (0, 0)), mode="reflect", reflect_type="odd")
    result = run("ffmpeg", "-hide_banner", "-nostats", "-f", "f32le", "-ar", str(rate),
                 "-ac", str(audio.shape[1]), "-i", "-", "-af", f"adeclick=t={threshold:g}",
                 "-c:a", "pcm_f32le", "-f", "f32le", "-", data=extended.astype("<f4").tobytes())
    repaired = np.frombuffer(result.stdout, dtype="<f4").reshape(-1, audio.shape[1])[guard:-guard].copy()
    assert repaired.shape == audio.shape, "Repair changed frame count"
    return repaired, result.stderr


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--repair", action="store_true", help="Produce an experimental FLAC and A/B excerpts")
    parser.add_argument("--threshold", type=float, default=6, help="1-100; lower values repair more aggressively (default: 6)")
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    os.environ.setdefault("MPLCONFIGDIR", str(out / "matplotlib-cache"))
    os.environ.setdefault("XDG_CACHE_HOME", str(out / "cache"))
    # Desktop's bundled packaging is a pure-Python fallback for partial system installs.
    bundled = Path("/Users/chenrenwei/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/lib/python3.12/site-packages")
    if bundled.exists():
        sys.path.append(str(bundled))
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.ticker import FuncFormatter

    metadata = json.loads(run("ffprobe", "-v", "error", "-select_streams", "a:0",
                              "-show_streams", "-show_format", "-of", "json", str(args.input)).stdout)
    stream = metadata["streams"][0]
    rate, channels = int(stream["sample_rate"]), int(stream["channels"])
    decoded = run("ffmpeg", "-hide_banner", "-v", "warning", "-i", str(args.input),
                  "-map", "0:a:0", "-c:a", "pcm_f32le", "-f", "f32le", "-")
    audio = np.frombuffer(decoded.stdout, dtype="<f4").reshape(-1, channels)
    assert np.isfinite(audio).all(), "Decoded audio contains non-finite samples"
    duration = len(audio) / rate
    warnings = decoded.stderr.decode(errors="replace")
    (out / "decode.log").write_text(warnings)
    loudness = run("ffmpeg", "-hide_banner", "-nostats", "-i", str(args.input),
                   "-map", "0:a:0", "-af", "ebur128=peak=true", "-f", "null", "-").stderr.decode(errors="replace")
    (out / "loudness.log").write_text(loudness)

    # Chart contract: full 200 s coverage; independent channel power averaged,
    # never a mono downmix; PSD in dBFS/Hz; candidates explicitly provisional.
    # Static scientific artifact, blue/gold palette and shared time axes.
    nfft, hop = 2048, 512
    psd = None
    spectra = []
    for channel in range(channels):
        f, t, p = signal.spectrogram(audio[:, channel], rate, window="hann", nperseg=nfft,
                                     noverlap=nfft-hop, scaling="density", mode="psd")
        psd = p / channels if psd is None else psd + p / channels
        wf, wp = signal.welch(audio[:, channel], rate, nperseg=8192, scaling="density")
        spectra.append(wp)
    average = np.mean(spectra, axis=0)
    total = psd.sum(axis=0)
    band_edges = [0, 200, 2000, 5000, 10000, 16000, rate/2]
    band_stats = []
    for lo, hi in zip(band_edges[:-1], band_edges[1:]):
        mask = (f >= lo) & (f < hi)
        band_stats.append({"low_hz": lo, "high_hz": hi,
                           "energy_percent": float(psd[mask].sum() / psd.sum() * 100)})
    high_fraction = psd[f >= 10000].sum(axis=0) / np.maximum(total, 1e-20) * 100
    # Ignore silence when describing ratios and ranking high-frequency windows.
    active = total * (rate / nfft) > 1e-6
    hf_power = psd[f >= 10000].sum(axis=0)
    peaks, _ = signal.find_peaks(hf_power, distance=max(1, int(.1*rate/hop)))
    highest = sorted(peaks, key=lambda i: float(hf_power[i]), reverse=True)[:20]
    rms = np.sqrt(np.mean(audio.astype(np.float64)**2, axis=0))
    peak = np.max(np.abs(audio), axis=0)
    stats = {
        "source": str(args.input.resolve()), "sha256": hashlib.sha256(args.input.read_bytes()).hexdigest(),
        "sample_rate": rate, "channels": channels, "frames": len(audio), "duration_seconds": duration,
        "codec": stream["codec_name"], "bit_rate": stream.get("bit_rate"),
        "peak_dbfs_per_channel": db(peak).tolist(), "rms_dbfs_per_channel": db(rms).tolist(),
        "over_full_scale_samples": int(np.sum(np.abs(audio) >= 1)),
        "decode_warnings": warnings, "bands": band_stats,
        "high_frequency_energy_percent": float(psd[f >= 10000].sum()/psd.sum()*100),
        "above_16khz_energy_percent": float(psd[f >= 16000].sum()/psd.sum()*100),
        "stft": {"window": "Hann", "fft_frames": nfft, "hop_frames": hop,
                 "frequency_resolution_hz": rate/nfft, "time_step_seconds": hop/rate,
                 "aggregation": "mean of independent channel power, no mono downmix"},
        "high_frequency_windows": [{"seconds": float(t[i]), "above_10khz_fraction_percent": float(high_fraction[i])} for i in highest],
    }
    candidates = []
    repaired = None
    if args.repair:
        repaired, filter_log = repair_impulses(audio, rate, args.threshold)
        (out / "adeclick.log").write_bytes(filter_log)
        delta = repaired - audio
        difference = np.max(np.abs(delta), axis=1)
        changed = np.flatnonzero(difference > 1e-4)
        groups = np.split(changed, np.flatnonzero(np.diff(changed) > .01*rate)+1) if len(changed) else []
        for group in groups:
            i = int(group[np.argmax(difference[group])])
            candidates.append({"seconds": i/rate, "frame": i, "maximum_change": float(difference[i]),
                               "affected_frames_above_0_0001": len(group),
                               "group_span_ms": float((group[-1]-group[0]+1)*1000/rate)})
        candidates.sort(key=lambda item: item["maximum_change"], reverse=True)
        stats["repair_trial"] = {
            "filter": f"FFmpeg adeclick=t={args.threshold:g}; 100 ms odd-reflection guards trimmed sample-exact",
            "status": "experimental, no subjective confirmation",
            "frame_count_preserved": True, "difference_rms_dbfs": float(db(np.sqrt(np.mean(delta.astype(np.float64)**2)))),
            "frames_changed_above_0_001": int(np.sum(difference > .001)),
            "frames_changed_above_0_001_percent": float(np.mean(difference > .001)*100),
            "peak_dbfs": float(db(np.max(np.abs(repaired)))), "candidates": candidates,
        }
        run("ffmpeg", "-v", "error", "-f", "f32le", "-ar", str(rate), "-ac", str(channels),
            "-i", "-", "-c:a", "flac", "-y", str(out / "experimental-declick.flac"), data=repaired.astype("<f4").tobytes())

    plt.rcParams.update({"font.family": "DejaVu Sans", "font.size": 10,
                         "axes.spines.top": False, "axes.spines.right": False,
                         "axes.labelcolor": "#333333", "text.color": "#222222",
                         "axes.titleweight": "bold", "figure.facecolor": "white"})
    fmt = FuncFormatter(lambda v, _: f"{int(v)//60}:{int(v)%60:02}")
    blue, gold = "#2A628F", "#B27920"
    fig, ax = plt.subplots(4, 1, figsize=(15, 12), gridspec_kw={"height_ratios": [1, 2.2, .85, 1.35]}, layout="constrained")
    fig.suptitle("Full-track audio spectrum and transient analysis", fontsize=19, x=.04, ha="left")
    ax[0].set_title(f"Decoded waveform | {duration:.3f} s, {rate:,} Hz, {channels} channels", loc="left")
    stride = int(.025*rate)
    length = len(audio)//stride*stride
    envelope = audio[:length].reshape(-1, stride, channels)
    time = (np.arange(len(envelope))+.5)*stride/rate
    ax[0].fill_between(time, envelope.min(axis=(1,2)), envelope.max(axis=(1,2)), color=blue, linewidth=0)
    ax[0].axhline(1, color="#777777", ls="--", lw=.6)
    ax[0].axhline(-1, color="#777777", ls="--", lw=.6)
    ax[0].set(ylabel="Amplitude (FS)", ylim=(-1.05, 1.05))
    mesh = ax[1].pcolormesh(t, f/1000, 10*np.log10(np.maximum(psd, 1e-15)),
                           shading="auto", cmap="magma", vmin=-115, vmax=-35, rasterized=True)
    ax[1].set_title("Spectrogram | Hann 2048 samples; 11.61 ms hop; independent channel power averaged", loc="left")
    ax[1].set(ylabel="Frequency (kHz)", ylim=(0, rate/2000))
    fig.colorbar(mesh, ax=ax[1], label="PSD (dBFS/Hz)", fraction=.02, pad=.01)
    ax[2].plot(t, np.where(active, high_fraction, np.nan), color=blue, lw=.7)
    ax[2].set_title("Energy above 10 kHz as a share of total | windows below -60 dBFS excluded", loc="left")
    ax[2].set(ylabel="Energy (%)", ylim=(0, 100))
    for a in ax[:3]:
        a.set_xlim(0, duration)
        a.xaxis.set_major_formatter(fmt)
        a.grid(axis="x", alpha=.15)
    ax[2].set_xlabel("Time (m:ss)")
    ax[3].plot(wf/1000, 10*np.log10(np.maximum(average, 1e-15)), color=blue, lw=1)
    ax[3].set(xlabel="Frequency (kHz)", ylabel="Mean PSD\n(dBFS/Hz)", xlim=(0, rate/2000), ylim=(-125,-30))
    ax[3].set_title("Whole-track mean spectrum | Welch 8192 samples; channel power averaged", loc="left")
    ax[3].grid(alpha=.15)
    fig.savefig(out / "full-track-spectrum.png", dpi=150)
    plt.close(fig)

    if repaired is not None and candidates:
        chosen = candidates[:4]
        fig, axes = plt.subplots(4, 2, figsize=(15, 11), layout="constrained")
        fig.suptitle("Provisional impulse candidates: original vs conservative repair", fontsize=18)
        for row, candidate in enumerate(chosen):
            i = candidate["frame"]
            channel = int(np.argmax(np.abs(repaired[i]-audio[i])))
            start, end = max(0, i-int(.003*rate)), min(len(audio), i+int(.003*rate))
            relative = (np.arange(start,end)-i)*1000/rate
            axes[row,0].plot(relative, audio[start:end,channel], color=blue, lw=1, label="Original")
            axes[row,0].plot(relative, repaired[start:end,channel], color=gold, lw=1, ls="--", label=f"adeclick t={args.threshold:g}")
            axes[row,0].set_title(f"{i/rate:.6f} s | channel {channel+1} | +/-3 ms", loc="left")
            axes[row,0].set(xlabel="Relative time (ms)", ylabel="Amplitude (FS)")
            axes[row,0].legend(loc="upper right", fontsize=8)
            start, end = max(0,i-int(.1*rate)), min(len(audio),i+int(.1*rate))
            df,dt,dp=signal.spectrogram(audio[start:end,channel],rate,window="hann",nperseg=256,noverlap=240)
            axes[row,1].pcolormesh((dt+start/rate-i/rate)*1000,df/1000,10*np.log10(np.maximum(dp,1e-15)),
                                   cmap="magma",vmin=-115,vmax=-35,shading="auto")
            axes[row,1].set(xlabel="Relative time (ms)",ylabel="Frequency (kHz)")
            axes[row,1].set_title("Original local spectrum | 5.80 ms window",loc="left")
            # Matched excerpt pair; no independent normalisation or level change.
            a,b=max(0,i-2*rate),min(len(audio),i+2*rate)
            for label,samples in [("original",audio),("repaired",repaired)]:
                run("ffmpeg","-v","error","-f","f32le","-ar",str(rate),"-ac",str(channels),"-i","-",
                    "-c:a","pcm_s24le","-y",str(out/f"{row+1:02}-{i/rate:.3f}s-{label}.wav"),
                    data=samples[a:b].astype("<f4").tobytes())
        fig.savefig(out / "impulse-details.png", dpi=150)
        plt.close(fig)
    (out / "analysis.json").write_text(json.dumps(stats, ensure_ascii=False, indent=2)+"\n")
    print(json.dumps({key: value for key,value in stats.items() if key not in ["high_frequency_windows","repair_trial"]},ensure_ascii=False,indent=2))
    if candidates:
        print("Largest provisional candidates:",json.dumps(candidates[:8],indent=2))


if __name__ == "__main__":
    main()
