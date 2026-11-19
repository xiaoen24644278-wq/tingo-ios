import "./style.css";
import { api, type Config, initApi, type Job } from "./api";
import { applyLang, renderShell, t } from "./i18n";
import { checkUpdate } from "./update";
import { shouldOnboard } from "./views/welcome";
import { $, setupModal } from "./dom";
import { poll } from "./poll";
import { route } from "./router";
import { refreshShell, setupShell } from "./shell";
import { refreshEnv, refreshMeetings } from "./sidebar";
import { S } from "./state";
import { setupPlayerKeys } from "./views/detail";
import { setupImport } from "./views/home";

/** 启动画面：至少展示 650ms（避免一闪而过），之后淡出并移除 */
function hideSplash(startedAt: number): void {
  const el = document.getElementById("splash");
  if (!el) return;
  const wait = Math.max(0, 650 - (performance.now() - startedAt));
  setTimeout(() => {
    el.classList.add("out");
    const done = () => el.remove();
    el.addEventListener("transitionend", done, { once: true });
    setTimeout(done, 900); // 兜底：过渡事件没触发也能移除
  }, wait);
}

async function boot(): Promise<void> {
  const startedAt = performance.now();
  setupShell();
  try {
    await initApi();
  } catch (e) {
    $("#main").innerHTML = `<div class="page"><div class="empty"><h3>${t("本地服务没有启动", "The local service didn't start")}</h3><div>${String(e)}</div></div></div>`;
    hideSplash(startedAt);
    return;
  }
  // 界面语言存在配置里；启动时先用上次记住的语言渲染，拿到配置后不一致再改
  try {
    applyLang(((await api<Config>("/api/config")).ui_language ?? "auto") as "auto");
  } catch {
    /* 拿不到配置就按系统语言 */
  }
  renderShell();
  refreshShell();
  setupModal();
  setupImport();
  setupPlayerKeys();
  window.addEventListener("hashchange", route);
  await Promise.all([refreshEnv(), refreshMeetings()]);
  try {
    S.job = await api<Job>("/api/job");
  } catch {
    /* 服务刚起来 */
  }
  // 第一次打开：先走新手引导
  if (shouldOnboard() && (!location.hash || location.hash === "#/")) location.hash = "#/welcome";
  route();
  hideSplash(startedAt);
  poll();
  // 有新版本时侧栏版本号旁边亮起提示
  checkUpdate().then((u) => {
    if (u?.newer) refreshEnv();
  });
}

boot();
