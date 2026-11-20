import "./style.css";
import { api, type Config, initApi, type Job } from "./api";
import { applyLang, renderShell, t } from "./i18n";
import { checkUpdate } from "./update";
import { shouldOnboard } from "./views/welcome";
import { $, esc, setupModal } from "./dom";
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
  // 硬兜底：不管初始化成功还是抛错，8 秒内一定撤掉启动画面，绝不把用户卡在黑屏
  const guard = window.setTimeout(() => hideSplash(startedAt), 8000);
  try {
    await bootInner(startedAt);
  } catch (err) {
    // 启动失败也要让用户看到原因（否则就是一片黑）
    const main = document.getElementById("main");
    if (main) {
      main.innerHTML = `<div class="page"><div class="empty"><h3>${t("启动失败", "Failed to start")}</h3><div style="word-break:break-all;font-size:12.5px">${esc(String(err))}</div></div></div>`;
    }
  } finally {
    window.clearTimeout(guard);
    hideSplash(startedAt);
  }
}

async function bootInner(startedAt: number): Promise<void> {
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
  // 界面骨架出来后立刻撤掉启动画面：后面的数据加载慢或失败，也不会让人一直盯着黑屏
  hideSplash(startedAt);
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
