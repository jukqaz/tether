(() => {
  "use strict";

  const form = document.querySelector("#combination-form");
  const menuTitles = { concise: "간결 메뉴", balanced: "균형 메뉴", rich: "옵션 풍부 메뉴" };
  const settingsTitles = { tabs: "상단 탭 설정", sidebar: "좁은 사이드바 설정" };
  const menuDescriptions = {
    concise: "상태·시간·기본 토글을 최소한의 행으로 배치하고",
    balanced: "상태·타이머·기본 토글을 구분하고",
    rich: "기본 조작에 접어 볼 수 있는 적용 상태를 더하고"
  };
  const settingsDescriptions = {
    tabs: "3~4개 상단 탭으로 설정을 정리합니다.",
    sidebar: "세로 분류를 유지하며 본문 폭과 창 너비를 조정합니다."
  };

  function updateCombination() {
    const values = new FormData(form);
    const menu = values.get("menu");
    const settings = values.get("settings");
    document.querySelector("#combination-title").textContent = `${menuTitles[menu]} + ${settingsTitles[settings]}`;
    document.querySelector("#combination-description").textContent = `${menuDescriptions[menu]}, ${settingsDescriptions[settings]}`;
  }
  form.addEventListener("change", updateCombination);
  form.addEventListener("reset", () => requestAnimationFrame(updateCombination));

  const stateLabels = { running: "잠자기 방지 중", ready: "타이머 시작 전", paused: "모두 중지됨" };
  const stateButtons = document.querySelectorAll("[data-state]");
  stateButtons.forEach(button => {
    button.addEventListener("click", () => {
      const state = button.dataset.state;
      stateButtons.forEach(item => item.setAttribute("aria-pressed", String(item === button)));
      document.querySelectorAll("[data-session]").forEach(panel => {
        panel.hidden = panel.dataset.session !== state;
      });
      document.querySelector(".wire-menu").dataset.state = state;
      document.querySelector("#wire-state-label").textContent = stateLabels[state];
      document.querySelector("#wire-footer-action").textContent = state === "paused" ? "타이머 복원 없음" : "모두 중지";
    });
  });

  document.querySelectorAll("img").forEach(img => {
    const showFailure = () => {
      const container = img.parentElement;
      const fallback = container.querySelector(".image-error");
      if (!fallback) return;
      img.hidden = true;
      fallback.hidden = false;
      container.classList.add("image-failed");
    };
    img.addEventListener("error", showFailure, { once: true });
    if (img.complete && img.naturalWidth === 0) showFailure();
  });
})();
