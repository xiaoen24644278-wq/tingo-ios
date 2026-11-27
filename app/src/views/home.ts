/* 首页：录音表单 → 录音中（计时、电平、实时文字）→ 结束后立刻回到录音表单，转写和生成纪要在后台进行，
   进度显示在玻璃面板下方和侧边栏。第一次使用时玻璃面板里下载识别模型。另含拖拽导入。 */

import { t } from "../i18n";
import { api, isMobile, url, type Job } from "../api";
import { $, $maybe, errorMessage, esc, ICON, main, toast } from "../dom";
import { poll } from "../poll";
import { refreshEnv, refreshMeetings } from "../sidebar";
import { isBusy, needsModels, S } from "../state";
import { dismissJob, renderTasks } from "../tasks";
import { isRecordingPage, leaveRecording, renderRecording, updateRecording } from "./recording";

type Phase = "idle" | "recording" | "downloading" | "error";

const INIT: Job = { state: "idle" };
const phaseOf = (j: Job): Phase =>
  j.state === "recording" ? "recording" : j.kind === "models" && isBusy(j) ? "downloading" : j.kind === "models" && j.state === "error" ? "error" : "idle";

export function renderHome(): void {
  // 录音中：整页换成录音工作台
  if (phaseOf(S.job) === "recording") {
    renderRecording(S.job);
    bindStop();
    updateRecording(S.job);
    return;
  }
  leaveRecording();
  const modelReady = !needsModels();
  const mark = document.querySelector(".brand-mark")?.innerHTML ?? "";
  main().innerHTML = `
    <div class="page home-page">
      ${
        isMobile()
          ? `<div class="m-top">
              <div class="m-brand"><span class="m-logo">${mark}</span><b>会听</b><small>HuiT</small></div>
              <a class="m-pill ${modelReady ? "ok" : "warn"}" href="#/settings/asr"><i></i>${modelReady ? t("模型已就绪", "Model ready") : t("模型未下载", "Model needed")}</a>
            </div>`
          : `<div class="hero-head">
              <span class="hero-tag"><b></b>${t("本地转写 · 录音不出本机", "On-device transcription · audio never leaves your Mac")}</span>
              <h1>${t("开个会，纪要交给我", "Have the meeting. HuiT takes the notes.")}</h1>
              <p>${t("录下会议，自动转写、区分说话人，整理出议题、决议和待办", "Record, transcribe, tell speakers apart — and get topics, decisions and action items")}</p>
            </div>`
      }
      <section class="aurora" id="aurora">
        <div class="aurora-colors" aria-hidden="true"><i class="blob b1"></i><i class="blob b2"></i><i class="blob b3"></i><i class="blob b4"></i><i class="grain"></i></div>
        <div class="glass-ring"><div class="glass" id="glass"></div></div>
      </section>
      <div class="home-tasks" id="homeTasks"></div>
      <div class="quick">
        <div class="quick-item quick-import" id="qImport"><span class="ico">${ICON.upload}</span><span><b>${isMobile() ? t("导入已有录音 / 视频", "Import audio or video") : t("导入录音", "Import recording")}</b><small>${isMobile() ? t("支持 m4a、mp3、wav、mp4 等格式", "m4a, mp3, wav, mp4 and more") : t("拖进窗口，或点这里选文件", "Drop it in, or click to choose a file")}</small></span>${ICON.chevron}</div>
        <a class="quick-item" href="#/meetings"><span class="ico">${ICON.file}</span><span><b>${t("会议记录", "Meetings")}</b><small id="qCount">${t("查看全部会议", "See all meetings")}</small></span>${ICON.chevron}</a>
        <a class="quick-item" href="#/settings/llm"><span class="ico">${ICON.bot}</span><span><b>${t("大模型", "LLM")}</b><small id="qModel">${t("设置纪要用的模型", "Choose the model that writes minutes")}</small></span>${ICON.chevron}</a>
        <a class="quick-item" href="#/settings/push"><span class="ico">${ICON.send}</span><span><b>${t("推送到群", "Share to chat")}</b><small>${t("飞书 · 钉钉 · 企业微信", "Feishu · DingTalk · WeCom")}</small></span>${ICON.chevron}</a>
      </div>
    </div>`;
  $("#qImport").onclick = () => $("#fileInput").click();
  if (S.meetings.length) $("#qCount").textContent = t(`共 ${S.meetings.length} 场会议`, `${S.meetings.length} meetings`);
  if (S.env) $("#qModel").textContent = S.env.llm_ready ? t(`当前：${S.env.llm_model}`, `Using ${S.env.llm_model}`) : t("还没有配置", "Not set up yet");
  updateHome(S.job, INIT, true);
  renderTasks();
}

export function updateHome(job: Job, prev: Job, forceRender = false): void {
  const phase = phaseOf(job);
  if (phase === "recording") {
    if (!isRecordingPage()) {
      renderRecording(job);
      bindStop();
    }
    return updateRecording(job);
  }
  if (isRecordingPage()) return renderHome();
  const glass = $maybe("#glass");
  if (!glass) return;
  const aurora = $("#aurora");
  aurora.classList.toggle("live", false);
  if (forceRender || phase !== phaseOf(prev) || glass.dataset.phase !== phase) {
    glass.dataset.phase = phase;
    glass.innerHTML = VIEWS[phase](job);
    bindHome(phase);
  }
  if (phase === "downloading") updateDownloading(job);
}


function downloadPanel(): string {
  const mb = S.env?.models_size_mb ?? 330;
  return `
    <div class="live-head" style="color:var(--blue)">${t("第一次使用", "First run")}</div>
    <div class="timer" style="font-size:22px;margin:12px 0 6px;font-family:var(--font)">${t(`先下载识别模型（约 ${mb} MB）`, `Download the speech model first (~${mb} MB)`)}</div>
    <div class="proc-note">${t("只需下载一次。识别、区分说话人都在这台设备上完成，录音不会上传。", "One-time download. Recognition and speaker separation run on this Mac — your audio is never uploaded.")}</div>
    <div class="glass-foot">
      <span class="spacer"></span>
      <button class="btn primary" id="dlBtn">${t("下载模型", "Download")}</button>
    </div>`;
}

/** 麦克风被拒绝 / 还没授权时的提示条：手机上点录音没反应，多半是这一步没过 */
function micBanner(): string {
  bindMicFix();
  const st = S.env?.mic_status;
  if (!st || st === "granted" || isMobile() === false) return "";
  const denied = st === "denied";
  return `<button class="mic-banner${denied ? " denied" : ""}" id="micFix" type="button">
    ${ICON.mic}
    <span>${
      denied
        ? t("麦克风被拒绝了：「设置 → 会听HuiT → 麦克风」打开后回到这里", "Microphone denied — turn it on in Settings → HuiT → Microphone")
        : t("点这里允许麦克风，才能录下会议", "Tap to allow the microphone so meetings can be recorded")
    }</span>
  </button>`;
}

// 点提示条 → 主动请求权限（会弹系统授权框）。用幂等注册，避免模块被多次引入时绑多次。
let micFixBound = false;
function bindMicFix(): void {
  if (micFixBound) return;
  micFixBound = true;
  document.addEventListener("click", async (ev) => {
    const target = ev.target as HTMLElement | null;
    if (!target?.closest("#micFix")) return;
    ev.preventDefault();
    try {
      const r = await api<{ status: string; error?: string }>("/api/mic", { method: "POST" });
      if (r.error) toast(r.error, true);
    } catch (e) {
      toast(errorMessage(e), true);
    }
    await refreshEnv();
  });
}

function idleForm(): string {
  if (needsModels()) return downloadPanel();
  const sys = S.env ? S.env.system_audio : true;
  return `
    ${micBanner()}
    ${isMobile() ? `<div class="glass-kicker">${t("本地转写 · 隐私不出设备", "On-device · Private")}</div>` : ""}
    <input class="title-input" id="fTitle" placeholder="${t("会议名称，比如：周会、项目评审", "Meeting name, e.g. Weekly sync, Design review")}" value="${esc(S.form.title)}" maxlength="60">
    <input class="hot-input" id="fHot" placeholder="${t("热词（可选）：人名、项目代号、专有名词，用逗号隔开", "Hotwords (optional): names, project codes, jargon — comma separated")}" value="${esc(S.form.hotwords)}">
    <div class="glass-foot">
      ${isMobile() ? "" : `<button class="toggle ${S.form.system && sys ? "on" : ""}" id="tSys" aria-pressed="${Boolean(S.form.system && sys)}" ${sys ? "" : `disabled title='${t("需要 macOS 15+", "Requires macOS 15+")}'`}>${ICON.monitor}${t("系统声音", "System audio")}</button>`}
      <button class="toggle ${S.form.mic ? "on" : ""}" id="tMic" aria-pressed="${Boolean(S.form.mic)}">${ICON.mic}${t("麦克风", "Microphone")}</button>
      <span class="spacer"></span>
      <span class="rec-label" id="recLabelDesktop">${t("开始录音", "Record")}</span>
      <button class="rec-btn" id="recBtn" aria-label="${t("开始录音", "Start recording")}" title="${t("开始录音", "Start recording")}"><span class="core" aria-hidden="true"></span><span class="rec-btn-text" id="recBtnText">${t("开始现场录音", "Start recording")}</span></button>
    </div>`;
}

const downloadingView = () => `
  <div class="live-head" style="color:var(--blue)"><span class="live-dot" style="background:var(--cyan)"></span>${t("下载识别模型", "Downloading the speech model")}</div>
  <div class="timer" id="dlText" style="font-size:22px;margin:12px 0 10px">0 MB</div>
  <div class="steps" style="grid-template-columns:1fr"><div class="step now"><div class="bar"><div id="dlBar" style="position:absolute;inset:0 auto 0 0;width:0;background:linear-gradient(90deg,var(--cyan),var(--blue));border-radius:99px"></div></div></div></div>
  <div class="proc-note">${t("识别模型来自 ModelScope，标点和声纹模型来自 GitHub；网络中断会自动续传", "Speech model from ModelScope, punctuation and voiceprint models from GitHub — interrupted downloads resume automatically")}</div>`;

function updateDownloading(job: Job): void {
  const m = /([\d.]+)\s*\/\s*([\d.]+)/.exec(job.stage ?? "");
  $("#dlText").textContent = job.stage || t("准备下载…", "Starting download…");
  if (m) $("#dlBar").style.width = `${Math.min(100, (Number(m[1]) / Number(m[2])) * 100).toFixed(1)}%`;
}

const errorView = (job: Job) => `
  <div class="live-head">${t("模型下载没有完成", "The model download didn't finish")}</div>
  <div class="err-box" style="margin-top:12px">${esc(job.error)}</div>
  <div class="proc-note">${t("已下载的部分会保留，重试时接着下", "What's downloaded is kept — retrying resumes from there")}</div>
  <div class="glass-foot">
    <button class="btn" id="againBtn">${t("关闭", "Close")}</button>
    <span class="spacer"></span>
    <button class="btn primary" id="dlBtn">${t("重试", "Retry")}</button>
  </div>`;

const VIEWS: Record<Phase, (job: Job) => string> = {
  idle: idleForm,
  recording: () => "", // 录音中整页换成录音工作台（recording.ts）
  downloading: downloadingView,
  error: errorView,
};

function bindHome(phase: Phase): void {
  const dl = $maybe("#dlBtn");
  if (dl) {
    dl.onclick = async () => {
      (dl as HTMLButtonElement).disabled = true;
      try {
        S.job = await api<Job>("/api/models/download", { method: "POST" });
        poll();
      } catch (e) {
        toast(errorMessage(e), true);
        (dl as HTMLButtonElement).disabled = false;
      }
    };
  }
  if (phase === "idle" && !needsModels()) {
    const title = $<HTMLInputElement>("#fTitle");
    title.oninput = () => (S.form.title = title.value);
    title.onkeydown = (e) => {
      if (e.key === "Enter") startRecording();
    };
    const hot = $<HTMLInputElement>("#fHot");
    hot.oninput = () => (S.form.hotwords = hot.value);
    // 手机上「系统声音」开关不渲染（录不到别的 App 的音频），这里必须容忍它不存在，
    // 否则 $() 会抛 "missing element #tSys"，整个启动流程就断在这
    const sysToggle = $maybe<HTMLElement>("#tSys");
    if (sysToggle) {
      sysToggle.onclick = (e) => {
        S.form.system = !S.form.system;
        (e.currentTarget as HTMLElement).classList.toggle("on", S.form.system);
        (e.currentTarget as HTMLElement).setAttribute("aria-pressed", String(S.form.system));
      };
    }
    $("#tMic").onclick = (e) => {
      S.form.mic = !S.form.mic;
      (e.currentTarget as HTMLElement).classList.toggle("on", S.form.mic);
      (e.currentTarget as HTMLElement).setAttribute("aria-pressed", String(S.form.mic));
    };
    $("#recBtn").onclick = startRecording;
  } else if (phase === "error") {
    $("#againBtn").onclick = async () => {
      const id = S.job.id;
      S.job = { state: "idle" };
      updateHome(S.job, INIT, true);
      if (id) await dismissJob(id);
    };
  }
}

async function startRecording(): Promise<void> {
  const sys = S.form.system && (!S.env || S.env.system_audio);
  if (!sys && !S.form.mic) return toast(t("系统声音和麦克风至少开一个", "Turn on system audio or the microphone"), true);
  const btn = $maybe<HTMLButtonElement>("#recBtn");
  if (btn?.disabled) return;
  if (btn) {
    btn.disabled = true;
    btn.setAttribute("aria-busy", "true");
  }
  const startedAt = performance.now();
  const labelDesktop = $maybe("#recLabelDesktop");
  const labelMobile = $maybe("#recBtnText");
  const setStage = (text: string) => {
    if (labelDesktop) labelDesktop.textContent = text;
    if (labelMobile) labelMobile.textContent = text;
  };
  setStage(t("正在启动…", "Starting…"));
  let diagTimer = 0;
  if (labelDesktop || labelMobile) {
    diagTimer = window.setInterval(async () => {
      const secs = Math.round((performance.now() - startedAt) / 1000);
      try {
        const d = await api<{ engine_loaded: boolean }>("/api/diag");
        setStage(
          d.engine_loaded
            ? t("正在打开麦克风…", "Opening the microphone…")
            : t(`正在加载识别模型…${secs}s`, `Loading the speech model… ${secs}s`),
        );
      } catch {
        setStage(t(`正在准备…${secs}s`, `Preparing… ${secs}s`));
      }
    }, 1000);
  }
  try {
    S.job = await api<Job>("/api/record/start", {
      json: {
        title: S.form.title.trim() || t("会议", "Meeting"),
        system: sys,
        mic: S.form.mic,
        hotwords: S.form.hotwords.split(/[,，、\s]+/).filter(Boolean),
      },
    });
    S.form.title = "";
    if (diagTimer) window.clearInterval(diagTimer);
    poll();
  } catch (e) {
    toast(errorMessage(e), true);
    if (diagTimer) window.clearInterval(diagTimer);
    if (labelDesktop) labelDesktop.textContent = t("开始录音", "Record");
    if (labelMobile) labelMobile.textContent = t("开始现场录音", "Start recording");
    if (btn) {
      btn.disabled = false;
      btn.removeAttribute("aria-busy");
    }
  }
}

function bindStop(): void {
  $("#stopBtn").onclick = stopRecording;
}

async function stopRecording(): Promise<void> {
  const btn = $<HTMLButtonElement>("#stopBtn");
  if (btn.disabled) return;
  btn.disabled = true;
  btn.setAttribute("aria-busy", "true");
  btn.textContent = t("正在保存…", "Saving…");
  btn.setAttribute("aria-label", btn.textContent);
  try {
    await api("/api/record/stop", { method: "POST" });
    toast(t("录音已保存，转写和纪要在后台进行，可以开始下一场", "Saved. Transcription and minutes continue in the background — you can start the next meeting"));
    S.job = { state: "idle" };
    updateHome(S.job, INIT, true);
    poll();
  } catch (e) {
    toast(errorMessage(e), true);
    btn.disabled = false;
    btn.removeAttribute("aria-busy");
    btn.textContent = t("结束录音", "Stop");
    btn.setAttribute("aria-label", t("结束录音", "Stop recording"));
  }
}

/* ---------- 导入 ---------- */

function showImportBanner(name: string, pct: number, stageText: string): void {
  const box = $maybe("#homeTasks");
  if (!box) return;
  let card = $maybe("#importProgressCard", box);
  if (!card) {
    card = document.createElement("div");
    card.id = "importProgressCard";
    card.className = "task big importing";
    box.prepend(card);
  }
  card.innerHTML = `
    <span class="task-ico"><span class="task-spin"></span></span>
    <span class="task-main">
      <span class="task-title">${esc(name)}</span>
      <span class="task-detail">${esc(stageText)}</span>
      <span class="task-bar"><i style="width:${Math.max(4, pct)}%"></i></span>
    </span>
    <span class="task-pct">${Math.round(pct)}%</span>`;
}

function clearImportBanner(): void {
  $maybe("#importProgressCard")?.remove();
}

export async function importFile(file: File | undefined): Promise<void> {
  if (!file) return;
  const title = file.name.replace(/\.[^.]+$/, "");
  const fd = new FormData();
  fd.append("file", file);
  fd.append("title", title);
  fd.append("modified", String(file.lastModified || 0));

  const sizeMb = (file.size / 1_000_000).toFixed(1);
  showImportBanner(title, 5, t(`正在读取音频文件（${sizeMb} MB）…`, `Reading audio file (${sizeMb} MB)…`));
  toast(t(`正在导入 ${file.name}…`, `Importing ${file.name}…`));

  try {
    const job = await new Promise<Job>((resolve, reject) => {
      const xhr = new XMLHttpRequest();
      xhr.open("POST", url("/api/import"));
      xhr.upload.onprogress = (ev) => {
        if (ev.lengthComputable && ev.total > 0) {
          const pct = Math.min(95, (ev.loaded / ev.total) * 100);
          showImportBanner(
            title,
            pct,
            pct < 92
              ? t(`正在上传音频… ${Math.round(pct)}%（${sizeMb} MB）`, `Uploading audio… ${Math.round(pct)}% (${sizeMb} MB)`)
              : t("正在写入本地会议目录…", "Saving to local meeting folder…"),
          );
        }
      };
      xhr.onload = () => {
        try {
          const data = JSON.parse(xhr.responseText || "{}");
          if (xhr.status >= 200 && xhr.status < 300) resolve(data as Job);
          else reject(new Error(typeof data.detail === "string" ? data.detail : t(`导入失败（${xhr.status}）`, `Import failed (${xhr.status})`)));
        } catch (err) {
          reject(err);
        }
      };
      xhr.onerror = () => reject(new Error(t("读取或传输录音文件中断，请重试", "Audio upload interrupted — please try again")));
      xhr.send(fd);
    });
    clearImportBanner();
    S.jobs = [...S.jobs.filter((j) => j.id !== job.id), job];
    renderTasks();
    void refreshMeetings();
    toast(t(`已导入「${title}」，正在转写与生成纪要`, `Imported "${title}" — transcribing and writing minutes`));
    if (job.meeting) {
      location.hash = `#/m/${encodeURIComponent(job.meeting)}`;
    }
    poll();
  } catch (e) {
    clearImportBanner();
    toast(errorMessage(e), true);
  }
}

export function setupImport(): void {
  const input = $<HTMLInputElement>("#fileInput");
  input.onchange = () => {
    importFile(input.files?.[0]);
    input.value = "";
  };
  const overlay = $("#dropOverlay");
  let depth = 0;
  window.addEventListener("dragenter", (e) => {
    if (e.dataTransfer?.types?.includes("Files")) {
      depth++;
      overlay.classList.add("show");
    }
  });
  window.addEventListener("dragleave", () => {
    if (--depth <= 0) {
      depth = 0;
      overlay.classList.remove("show");
    }
  });
  window.addEventListener("dragover", (e) => e.preventDefault());
  window.addEventListener("drop", (e) => {
    e.preventDefault();
    depth = 0;
    overlay.classList.remove("show");
    importFile(e.dataTransfer?.files[0]);
  });
}
