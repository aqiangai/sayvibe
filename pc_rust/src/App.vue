<script setup>
import { computed, onBeforeUnmount, onMounted, ref, watch } from "vue";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import QRCode from "qrcode";

const AUTO_IME_MODE_STORAGE_KEY = "sayvibe.desktop.autoImeMode";
const autoImeModeOptions = [
  {
    value: "review",
    label: "待修改",
    detail: "替换文本后停留在输入框中",
  },
  {
    value: "send",
    label: "直接发送",
    detail: "替换文本后自动回车",
  },
];

const relayConfig = ref({
  port: 18700,
  baseUrl: "http://127.0.0.1:18700",
});

const state = ref({
  autoImeEnabled: false,
  autoImeSupported: true,
  autoImeMode: "review",
  autoImePlatform: "unknown",
  autoImePlatformLabel: "当前系统",
  autoImeShortcutLabel: "N/A",
  autoImeHint: "输入前请把目标输入框置于焦点。",
  latestText: "",
  latestTimestamp: 0,
  syncCount: 0,
  lastSyncLength: 0,
  androidOnlineCount: 0,
  lastPushSource: null,
  lanIps: [],
});

const logs = ref([]);
const currentText = ref("");
const pairingQrDataUrl = ref("");
const unlisten = ref(null);
const isBooting = ref(true);
const runtimeStatus = ref({
  kind: "pending",
  detail: "正在连接桌面端中继服务...",
});

function isEditableElement(target) {
  if (!(target instanceof HTMLElement)) return false;
  return !!target.closest("input, textarea, [contenteditable='true']");
}

function preventDesktopSelectAll(event) {
  if (isEditableElement(event.target)) return;
  if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "a") {
    event.preventDefault();
  }
}

const statusPillText = computed(() => {
  if (runtimeStatus.value.kind === "online") return "服务在线";
  if (runtimeStatus.value.kind === "offline") return "连接断开";
  return "连接中";
});

const currentIps = computed(() => state.value.lanIps || []);
const primaryPairIp = computed(() => currentIps.value[0] || "");
const pairingUrl = computed(() => {
  if (!primaryPairIp.value) return "";
  const params = new URLSearchParams({
    ip: primaryPairIp.value,
    port: String(relayConfig.value.port || 18700),
  });
  return `sayvibe://pair?${params.toString()}`;
});
const formattedTime = computed(() => formatTime(state.value.latestTimestamp));
const formattedSource = computed(() => formatSource(state.value.lastPushSource));
const autoImeStateText = computed(() => {
  if (!state.value.autoImeSupported) return "状态：不可用";
  return state.value.autoImeEnabled ? "状态：已开启" : "状态：已关闭";
});
const autoImeControlText = computed(() => {
  if (!state.value.autoImeSupported) return "当前系统暂不支持";
  return "动作在手机端调整";
});

function formatTime(timestamp) {
  if (!timestamp) return "暂无";
  return new Date(timestamp).toLocaleString();
}

function formatSource(source) {
  return source === "mobile" ? "手机" : "-";
}

function setRuntimeState(kind, detail) {
  runtimeStatus.value = { kind, detail };
}

async function refreshPairingQr() {
  if (!pairingUrl.value) {
    pairingQrDataUrl.value = "";
    return;
  }

  try {
    pairingQrDataUrl.value = await QRCode.toDataURL(pairingUrl.value, {
      margin: 1,
      width: 220,
      color: {
        dark: "#1f2a44",
        light: "#00000000",
      },
    });
  } catch (error) {
    pairingQrDataUrl.value = "";
    pushLog("二维码生成失败", String(error));
  }
}

watch(pairingUrl, () => {
  void refreshPairingQr();
}, { immediate: true });

function pushLog(title, detail) {
  logs.value.unshift({
    id: `${Date.now()}-${Math.random().toString(16).slice(2)}`,
    title,
    detail,
    time: new Date().toLocaleTimeString(),
  });

  if (logs.value.length > 20) {
    logs.value.length = 20;
  }
}

function applyState(nextState) {
  state.value = {
    ...state.value,
    ...nextState,
  };
  currentText.value = state.value.latestText || "";
}

async function boot() {
  try {
    setRuntimeState("pending", "正在读取桌面端配置...");

    const [config, snapshot] = await Promise.all([
      invoke("get_relay_config"),
      invoke("get_relay_state"),
    ]);

    relayConfig.value = config;
    applyState(snapshot);
    await restoreAutoImeMode();
    await refreshPairingQr();
    setRuntimeState("online", "桌面端中继服务已启动。");
    pushLog("初始化完成", "已载入桌面端当前状态。");

    unlisten.value = await listen("relay://event", (event) => {
      const payload = event.payload || {};
      handleRelayEvent(payload);
    });
  } catch (error) {
    setRuntimeState("offline", "桌面端初始化失败，请检查 Rust 后端是否正常启动。");
    pushLog("初始化失败", String(error));
  } finally {
    isBooting.value = false;
  }
}

function readSavedAutoImeMode() {
  try {
    const saved = window.localStorage.getItem(AUTO_IME_MODE_STORAGE_KEY);
    if (saved === "review") return saved;
  } catch (error) {
    pushLog("读取偏好失败", String(error));
  }
  return null;
}

function saveAutoImeMode(mode) {
  try {
    window.localStorage.setItem(AUTO_IME_MODE_STORAGE_KEY, mode);
  } catch (error) {
    pushLog("保存偏好失败", String(error));
  }
}

async function restoreAutoImeMode() {
  const savedMode = readSavedAutoImeMode();
  if (!savedMode) {
    try {
      const actualMode = await invoke("set_auto_ime_mode", { mode: "review" });
      state.value.autoImeMode = actualMode || "review";
    } catch (error) {
      pushLog("恢复输出动作失败", String(error));
    }
    saveAutoImeMode("review");
    return;
  }

  try {
    const actualMode = await invoke("set_auto_ime_mode", { mode: savedMode });
    state.value.autoImeMode = actualMode || "review";
    saveAutoImeMode(state.value.autoImeMode);
  } catch (error) {
    pushLog("恢复输出动作失败", String(error));
  }
}

function handleRelayEvent(payload) {
  const type = payload?.type;

  if (type === "state") {
    applyState(payload);
    return;
  }

  if (type === "android_state") {
    state.value.androidOnlineCount = payload.count || 0;
    pushLog("连接变化", (payload.count || 0) > 0 ? `当前 ${payload.count} 台手机在线。` : "当前没有手机在线。");
    return;
  }

  if (type === "sync_text") {
    state.value.syncCount = payload.syncCount || 0;
    state.value.lastSyncLength = payload.length || 0;
    state.value.latestText = payload.text || "";
    state.value.latestTimestamp = payload.timestamp || 0;
    state.value.lastPushSource = payload.source || null;
    currentText.value = state.value.latestText;
    pushLog("收到同步", `文本长度 ${payload.length || 0}。`);
    return;
  }

  if (type === "auto_ime_changed") {
    state.value.autoImeEnabled = !!payload.enabled;
    pushLog("自动输出已更新", payload.enabled ? "自动输出已开启。" : "自动输出已关闭。");
    return;
  }

  if (type === "auto_ime_mode_changed") {
    state.value.autoImeMode = payload.mode || "review";
    saveAutoImeMode(state.value.autoImeMode);
    pushLog("输出动作已更新", `当前模式：${autoImeModeOptions.find((item) => item.value === state.value.autoImeMode)?.label || "待修改"}。`);
    return;
  }

  if (type === "auto_ime_error") {
    pushLog("自动输出异常", payload.message || "未知错误");
    return;
  }

  if (type === "auto_ime_info") {
    pushLog("自动输出执行", payload.message || "自动输出已执行。");
    return;
  }

  if (type === "relay_error") {
    setRuntimeState("offline", payload.message || "中继服务启动失败。");
    pushLog("中继服务异常", payload.message || "未知错误");
  }
}

async function writeClipboard(text, successText) {
  if (!text) {
    pushLog("复制未执行", "当前没有可复制内容。");
    return;
  }

  try {
    await navigator.clipboard.writeText(text);
    pushLog("已复制", successText);
  } catch (error) {
    pushLog("复制失败", String(error));
  }
}

async function toggleAutoIme(nextValue) {
  try {
    const enabled = await invoke("set_auto_ime", { enabled: nextValue });
    state.value.autoImeEnabled = !!enabled;
  } catch (error) {
    pushLog("设置失败", String(error));
  }
}

async function setAutoImeMode(nextMode) {
  try {
    const actualMode = await invoke("set_auto_ime_mode", { mode: nextMode });
    state.value.autoImeMode = actualMode || "review";
    saveAutoImeMode(state.value.autoImeMode);
  } catch (error) {
    pushLog("设置失败", String(error));
  }
}

function clearTextView() {
  currentText.value = "";
  pushLog("已清空", "仅清空了当前桌面窗口中的文本视图。");
}

function clearLogs() {
  logs.value = [];
  pushLog("记录已重置", "后续状态会继续追加。");
}

onMounted(() => {
  pushLog("控制台已打开", "等待桌面端中继初始化。");
  window.addEventListener("keydown", preventDesktopSelectAll);
  boot();
});

onBeforeUnmount(() => {
  if (typeof unlisten.value === "function") {
    unlisten.value();
  }
  window.removeEventListener("keydown", preventDesktopSelectAll);
});
</script>

<template>
  <main class="shell">
    <section class="card hero">
      <div class="brand">
        <img class="logo" src="/logo.svg" alt="say vibe logo" />
        <div>
          <span class="eyebrow">say vibe desktop</span>
          <h1>say vibe · 桌面控制台</h1>
          <p class="subtitle">
            扫码即可在手机上配对到这台电脑。
          </p>
        </div>
      </div>

      <div class="status-area">
        <div class="status-pill" :class="runtimeStatus.kind">{{ statusPillText }}</div>
        <div class="status-text">{{ runtimeStatus.detail }}</div>
        <div class="quick-grid">
          <div class="quick-card">
            <div class="label">手机连接</div>
            <div class="value">{{ state.androidOnlineCount }}</div>
          </div>
          <div class="quick-card">
            <div class="label">同步次数</div>
            <div class="value">{{ state.syncCount }}</div>
          </div>
          <div class="quick-card">
            <div class="label">最近长度</div>
            <div class="value">{{ state.lastSyncLength }}</div>
          </div>
        </div>
      </div>
    </section>

    <section class="grid">
      <section class="card panel">
        <h2>配对与控制</h2>
        <p>优先使用手机扫码配对；局域网地址保留给手动输入时兜底。</p>

        <div class="section">
          <div class="section-title">手机扫码配对</div>
          <div v-if="pairingUrl && pairingQrDataUrl" class="pairing-card">
            <div class="pairing-qr">
              <img class="pairing-qr-image" :src="pairingQrDataUrl" alt="say vibe 配对二维码" />
            </div>
            <div class="pairing-copy">
              <strong>{{ primaryPairIp }}:{{ relayConfig.port }}</strong>
              <p>手机端进入设置后点击“扫码配对”，即可填入并连接到这台电脑。</p>
              <div class="action-row">
                <button class="btn primary" type="button" @click="writeClipboard(pairingUrl, '配对链接已复制。')">
                  复制配对链接
                </button>
                <button class="btn ghost" type="button" @click="writeClipboard(`${primaryPairIp}:${relayConfig.port}`, '手动地址已复制。')">
                  复制手动地址
                </button>
              </div>
            </div>
          </div>
          <div v-else class="empty-state">
            未检测到可用于配对的局域网地址，请检查当前网络连接。
          </div>
        </div>

        <div class="section">
          <div class="section-title">局域网地址</div>
          <div class="mono">{{ currentIps.length > 0 ? currentIps.map((ip) => `${ip}:${relayConfig.port}`).join("\n") : "未找到可用 IPv4 地址" }}</div>
          <div class="action-row">
            <button class="btn ghost" type="button" @click="writeClipboard(currentIps.map((ip) => `${ip}:${relayConfig.port}`).join('\n'), '局域网地址已复制。')">
              复制地址
            </button>
          </div>
        </div>

        <div class="section">
          <div class="toggle-row">
            <div class="toggle-label">
              <strong>自动输出</strong>
              <span>收到同步文本后，可自动填入当前焦点输入框。</span>
            </div>
            <label class="switch">
              <input
                :checked="state.autoImeEnabled"
                :disabled="!state.autoImeSupported || isBooting"
                type="checkbox"
                @change="toggleAutoIme($event.target.checked)"
              />
              <span class="switch-track"></span>
            </label>
          </div>
          <div class="badge-row">
            <span class="badge">{{ autoImeStateText }}</span>
            <span class="badge">{{ autoImeControlText }}</span>
          </div>
        </div>
      </section>

      <section class="card panel">
        <h2>同步内容</h2>
        <p>这里显示最新同步文本。你可以直接复制，或在桌面端清空当前视图。</p>

        <div class="badge-row">
          <span class="badge">来源：{{ formattedSource }}</span>
          <span class="badge">更新时间：{{ formattedTime }}</span>
          <span class="badge">监听端口：{{ relayConfig.port }}</span>
        </div>

        <div class="mirror no-copy" @copy.prevent @cut.prevent>
          <pre :class="{ empty: !currentText }">{{ currentText || "等待同步文本..." }}</pre>
        </div>

        <div class="action-row">
          <button class="btn ghost" type="button" @click="clearTextView">
            清空视图
          </button>
          <button class="btn ghost" type="button" @click="clearLogs">
            清空记录
          </button>
        </div>

        <div class="log-list no-copy" @copy.prevent @cut.prevent>
          <div v-for="item in logs" :key="item.id" class="log-item">
            <strong>{{ item.title }}</strong>
            <p>{{ item.detail }}</p>
            <div class="time">{{ item.time }}</div>
          </div>
        </div>
      </section>
    </section>
  </main>
</template>
