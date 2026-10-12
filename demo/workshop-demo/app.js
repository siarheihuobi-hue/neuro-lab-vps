(function () {
  "use strict";

  var STORAGE_KEY = "workshop-demo.tasks.v1";   // unchanged from version 1: earlier user tasks stay readable
  var CHECK_KEY = "workshop-demo.check.v1";
  var DOC_TOKEN = Math.random().toString(36).slice(2) + Date.now().toString(36);   // identifies THIS page load

  var HANDOFF_MESSAGE =
    "Браузерный тест демо пройден: добавление, отметка выполнения, сохранение после обновления и удаление работают.\n" +
    "Продолжим обучение работе с моим сервером и нейрокомандой.\n" +
    "Сначала сверь сохранённое состояние и открытые пункты настройки.";

  var form = document.getElementById("add-form");
  var input = document.getElementById("task-input");
  var formError = document.getElementById("form-error");
  var list = document.getElementById("task-list");
  var emptyState = document.getElementById("empty-state");
  var counter = document.getElementById("counter");
  var clearDone = document.getElementById("clear-done");

  var checkBox = document.getElementById("check");
  var checkSteps = document.getElementById("check-steps");
  var checkHint = document.getElementById("check-hint");
  var checkStart = document.getElementById("check-start");
  var checkRetry = document.getElementById("check-retry");
  var checkCancel = document.getElementById("check-cancel");
  var doneBox = document.getElementById("check-done");
  var doneTitle = document.getElementById("done-title");
  var doneRetry = document.getElementById("done-retry");

  // localStorage can be unavailable (private mode, blocked storage): the app still works in memory,
  // but the practical check cannot prove persistence then and refuses to start.
  function storageWorks() {
    try {
      var k = "workshop-demo.probe";
      localStorage.setItem(k, "1");
      var ok = localStorage.getItem(k) === "1";
      localStorage.removeItem(k);
      return ok;
    } catch (e) {
      return false;
    }
  }
  var storageOk = storageWorks();

  function loadTasks() {
    try {
      var parsed = JSON.parse(localStorage.getItem(STORAGE_KEY) || "[]");
      if (!Array.isArray(parsed)) return [];
      return parsed.filter(function (t) {
        return t && typeof t.id === "string" && typeof t.text === "string";
      }).map(function (t) {
        return { id: t.id, text: t.text, done: Boolean(t.done) };
      });
    } catch (e) {
      return [];
    }
  }

  function saveTasks() {
    try {
      localStorage.setItem(STORAGE_KEY, JSON.stringify(tasks));
    } catch (e) {
      /* storage unavailable — keep working in memory */
    }
  }

  function newId() {
    return Date.now().toString(36) + Math.random().toString(36).slice(2, 8);
  }

  function pluralTasks(n) {
    var mod10 = n % 10, mod100 = n % 100;
    if (mod10 === 1 && mod100 !== 11) return "задача";
    if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) return "задачи";
    return "задач";
  }

  var tasks = loadTasks();

  // ---------- practical check: the app follows the scenario itself ----------
  // Phases: idle -> add -> mark -> reload -> delete -> done (or failed). Only tasks ADDED AFTER the start are tracked;
  // tasks that existed before are never read as progress and never deleted by the check.
  var PHASES = ["add", "mark", "reload", "delete", "done"];
  var STEP_ORDER = ["add", "mark", "reload", "delete"];
  var justCompleted = false;

  function emptyCheck() {
    return { v: 1, phase: "idle", ids: [], doneId: "", docToken: "", failReason: "", failedPhase: "", celebrated: false };
  }

  function loadCheck() {
    try {
      var c = JSON.parse(localStorage.getItem(CHECK_KEY) || "null");
      if (!c || typeof c !== "object") return emptyCheck();
      var phase = c.phase;
      if (phase !== "idle" && phase !== "failed" && PHASES.indexOf(phase) < 0) return emptyCheck();
      return {
        v: 1,
        phase: phase,
        ids: Array.isArray(c.ids) ? c.ids.filter(function (x) { return typeof x === "string"; }).slice(0, 2) : [],
        doneId: typeof c.doneId === "string" ? c.doneId : "",
        docToken: typeof c.docToken === "string" ? c.docToken : "",
        failReason: typeof c.failReason === "string" ? c.failReason : "",
        failedPhase: typeof c.failedPhase === "string" ? c.failedPhase : "",
        celebrated: Boolean(c.celebrated)
      };
    } catch (e) {
      return emptyCheck();
    }
  }

  var check = loadCheck();

  function saveCheck() {
    try {
      if (check.phase === "idle") localStorage.removeItem(CHECK_KEY);
      else localStorage.setItem(CHECK_KEY, JSON.stringify(check));
    } catch (e) {
      /* without storage the check cannot run; the start button is disabled */
    }
  }

  function checkActive() {
    return check.phase === "add" || check.phase === "mark" || check.phase === "reload" || check.phase === "delete";
  }

  function findTask(id) {
    for (var i = 0; i < tasks.length; i++) if (tasks[i].id === id) return tasks[i];
    return null;
  }

  function failCheck(reason) {
    check.failedPhase = check.phase;
    check.phase = "failed";
    check.failReason = reason;
    saveCheck();
  }

  function startCheck() {
    if (!storageOk) return;
    check = emptyCheck();
    check.phase = "add";
    saveCheck();
    renderCheck();
    input.focus();
  }

  function resetCheck() {
    check = emptyCheck();
    saveCheck();
    renderCheck();
    render();
  }

  function onTaskAdded(id) {
    if (check.phase !== "add") return;
    check.ids.push(id);
    if (check.ids.length >= 2) check.phase = "mark";
    saveCheck();
  }

  // After a checkbox change: exactly one of the two tracked tasks must be marked done.
  function onTasksToggled() {
    if (check.phase !== "mark" && check.phase !== "reload") return;
    var a = findTask(check.ids[0]), b = findTask(check.ids[1]);
    if (!a || !b) { failCheck("Одна из двух задач проверки пропала до шага удаления."); return; }
    var doneTasks = [a, b].filter(function (t) { return t.done; });
    if (doneTasks.length === 1) {
      check.phase = "reload";
      check.doneId = doneTasks[0].id;
      check.docToken = DOC_TOKEN;
    } else {
      check.phase = "mark";
      check.doneId = "";
    }
    saveCheck();
  }

  function onTaskDeleted(id) {
    if (!checkActive()) return;
    var tracked = check.ids.indexOf(id) >= 0;
    if (!tracked) return;   // deleting any other task is the person's own business and is ignored
    if (check.phase === "delete") {
      var other = check.ids[0] === check.doneId ? check.ids[1] : check.ids[0];
      if (id === check.doneId && findTask(other) && !findTask(other).done) {
        check.phase = "done";
        justCompleted = true;
        saveCheck();
      } else if (id === other) {
        failCheck("Удалена не та задача: нужно было удалить выполненную и оставить вторую.");
      }
      return;
    }
    failCheck("Задача проверки удалена слишком рано: сначала нужно пройти шаги по порядку.");
  }

  // A NEW page load while the check waits for the reload: the tracked tasks and the mark must have survived in storage.
  function verifyAfterReload() {
    if (check.phase !== "reload" || check.docToken === DOC_TOKEN) return;
    var a = findTask(check.ids[0]), b = findTask(check.ids[1]);
    var ok = a && b && findTask(check.doneId) && findTask(check.doneId).done;
    if (ok) {
      var other = check.ids[0] === check.doneId ? b : a;
      ok = !other.done;
    }
    if (ok) {
      check.phase = "delete";
      check.docToken = DOC_TOKEN;
      saveCheck();
    } else {
      failCheck("После обновления страницы задачи или отметка не сохранились.");
    }
  }

  function hintText() {
    switch (check.phase) {
      case "idle":
        return storageOk
          ? "Нажмите «Начать проверку»: приложение проследит за четырьмя шагами. Ваши прежние задачи не изменяются и не удаляются; во время проверки кнопка «Удалить выполненные» отключена."
          : "Браузер не разрешает хранить данные, поэтому проверку сохранения пройти нельзя. Откройте приложение в обычном окне браузера и обновите страницу.";
      case "add":
        return "Шаг 1. Добавьте две новые задачи (добавлено " + check.ids.length + " из 2).";
      case "mark":
        return "Шаг 2. Отметьте выполненной только одну из двух новых задач.";
      case "reload":
        return "Шаг 3. Обновите страницу (F5 или Ctrl+R). Приложение проверит, что обе задачи и отметка сохранились.";
      case "delete":
        return "Шаг 4. Удалите выполненную задачу и оставьте вторую.";
      case "failed":
        return check.failReason + " Нажмите «Повторить проверку»: ваши задачи останутся на месте.";
      default:
        return "";
    }
  }

  function renderCheck() {
    var cur = STEP_ORDER.indexOf(check.phase);
    var failIdx = check.phase === "failed" ? STEP_ORDER.indexOf(check.failedPhase) : -1;
    var items = checkSteps.querySelectorAll("li");
    for (var i = 0; i < items.length; i++) {
      var state = "pending", label = "ожидает";
      if (check.phase === "done") { state = "done"; label = "выполнено"; }
      else if (check.phase === "failed") {
        if (i < failIdx) { state = "done"; label = "выполнено"; }
        else if (i === failIdx) { state = "failed"; label = "не получилось"; }
      } else if (cur >= 0) {
        if (i < cur) { state = "done"; label = "выполнено"; }
        else if (i === cur) { state = "current"; label = "сейчас"; }
      }
      items[i].className = "check__step check__step--" + state;
      items[i].querySelector(".check__state").textContent = " — " + label;
    }
    checkHint.textContent = check.phase === "done" ? "" : hintText();
    checkStart.hidden = check.phase !== "idle";
    checkStart.disabled = !storageOk;
    checkRetry.hidden = check.phase !== "failed";
    checkCancel.hidden = !checkActive();
    checkBox.hidden = check.phase === "done";
    doneBox.hidden = check.phase !== "done";
    clearDone.disabled = checkActive();
    clearDone.title = checkActive() ? "Во время проверки отключено, чтобы не затронуть ваши прежние задачи" : "";
    if (check.phase === "done" && justCompleted) {
      justCompleted = false;
      doneTitle.focus();
      if (!check.celebrated) {
        check.celebrated = true;
        saveCheck();
        confetti();
      }
    }
  }

  // One short confetti burst when the check is completed. No libraries, no external services; skipped for
  // prefers-reduced-motion; it never takes pointer events or focus, so the buttons stay usable.
  function confetti() {
    try {
      if (window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;
      var canvas = document.createElement("canvas");
      canvas.className = "confetti";
      canvas.setAttribute("aria-hidden", "true");
      var w = canvas.width = window.innerWidth;
      var h = canvas.height = window.innerHeight;
      var ctx = canvas.getContext("2d");
      if (!ctx) return;
      document.body.appendChild(canvas);
      var colors = ["#4f46e5", "#f59e0b", "#10b981", "#ef4444", "#3b82f6", "#ec4899"];
      var parts = [];
      for (var i = 0; i < 120; i++) {
        parts.push({
          x: Math.random() * w, y: -20 - Math.random() * h * 0.3,
          vx: (Math.random() - 0.5) * 3, vy: 2 + Math.random() * 4,
          s: 4 + Math.random() * 6, r: Math.random() * Math.PI, vr: (Math.random() - 0.5) * 0.3,
          c: colors[i % colors.length]
        });
      }
      var start = Date.now();
      var DURATION = 2400;
      (function frame() {
        var t = Date.now() - start;
        ctx.clearRect(0, 0, w, h);
        if (t > DURATION) { if (canvas.parentNode) canvas.parentNode.removeChild(canvas); return; }
        ctx.globalAlpha = Math.max(0, 1 - t / DURATION);
        for (var j = 0; j < parts.length; j++) {
          var p = parts[j];
          p.x += p.vx; p.y += p.vy; p.vy += 0.04; p.r += p.vr;
          ctx.save();
          ctx.translate(p.x, p.y);
          ctx.rotate(p.r);
          ctx.fillStyle = p.c;
          ctx.fillRect(-p.s / 2, -p.s / 2, p.s, p.s * 0.6);
          ctx.restore();
        }
        window.requestAnimationFrame(frame);
      })();
    } catch (e) {
      /* decoration only */
    }
  }

  // ---------- task list ----------
  function render() {
    list.textContent = "";
    tasks.forEach(function (task) {
      var li = document.createElement("li");
      li.className = "task" + (task.done ? " task--done" : "");
      li.dataset.id = task.id;

      var checkbox = document.createElement("input");
      checkbox.type = "checkbox";
      checkbox.className = "task__check";
      checkbox.checked = task.done;
      checkbox.setAttribute("aria-label", "Отметить выполненной: " + task.text);

      var text = document.createElement("span");
      text.className = "task__text";
      text.textContent = task.text;

      var del = document.createElement("button");
      del.type = "button";
      del.className = "btn task__delete";
      del.textContent = "Удалить";
      del.setAttribute("aria-label", "Удалить задачу: " + task.text);

      li.append(checkbox, text, del);
      list.appendChild(li);
    });

    var doneCount = tasks.filter(function (t) { return t.done; }).length;
    emptyState.hidden = tasks.length > 0;
    counter.hidden = tasks.length === 0;
    counter.textContent = tasks.length + " " + pluralTasks(tasks.length) + ", выполнено: " + doneCount;
    clearDone.hidden = doneCount === 0;
    clearDone.disabled = checkActive();
  }

  form.addEventListener("submit", function (event) {
    event.preventDefault();
    var text = input.value.trim();
    if (!text) {
      formError.hidden = false;
      input.focus();
      return;
    }
    formError.hidden = true;
    var task = { id: newId(), text: text, done: false };
    tasks.push(task);
    saveTasks();
    onTaskAdded(task.id);
    render();
    renderCheck();
    input.value = "";
    input.focus();
  });

  input.addEventListener("input", function () {
    formError.hidden = true;
  });

  list.addEventListener("change", function (event) {
    if (!event.target.classList.contains("task__check")) return;
    var id = event.target.closest(".task").dataset.id;
    tasks.forEach(function (t) {
      if (t.id === id) t.done = event.target.checked;
    });
    saveTasks();
    onTasksToggled();
    render();
    renderCheck();
  });

  list.addEventListener("click", function (event) {
    if (!event.target.classList.contains("task__delete")) return;
    var id = event.target.closest(".task").dataset.id;
    tasks = tasks.filter(function (t) { return t.id !== id; });
    saveTasks();
    onTaskDeleted(id);
    render();
    renderCheck();
  });

  clearDone.addEventListener("click", function () {
    if (checkActive()) return;   // never delete earlier user tasks in the middle of the check
    tasks = tasks.filter(function (t) { return !t.done; });
    saveTasks();
    render();
  });

  // ---------- completion screen: two ready-made messages ----------
  function togglePanel(button, panelId) {
    var panel = document.getElementById(panelId);
    var open = panel.hidden;
    panel.hidden = !open;
    button.setAttribute("aria-expanded", open ? "true" : "false");
    if (open) panel.querySelector("textarea").focus();
  }
  document.getElementById("msg-gpt").value = HANDOFF_MESSAGE;
  document.getElementById("msg-vscode").value = HANDOFF_MESSAGE;
  document.getElementById("go-gpt").addEventListener("click", function () { togglePanel(this, "panel-gpt"); });
  document.getElementById("go-vscode").addEventListener("click", function () { togglePanel(this, "panel-vscode"); });

  function copyFrom(id) {
    var area = document.getElementById(id);
    var note = document.querySelector('[data-copied-for="' + id + '"]');
    function done(ok) { note.textContent = ok ? "Скопировано." : "Не удалось скопировать: выделите текст и скопируйте вручную (Ctrl+C)."; }
    area.focus();
    area.select();
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(area.value).then(function () { done(true); }, function () { done(legacyCopy()); });
    } else {
      done(legacyCopy());
    }
  }
  function legacyCopy() {
    try { return document.execCommand("copy"); } catch (e) { return false; }
  }
  Array.prototype.forEach.call(document.querySelectorAll("[data-copy]"), function (btn) {
    btn.addEventListener("click", function () { copyFrom(btn.getAttribute("data-copy")); });
  });

  checkStart.addEventListener("click", startCheck);
  checkRetry.addEventListener("click", resetCheck);
  checkCancel.addEventListener("click", resetCheck);
  doneRetry.addEventListener("click", resetCheck);

  // Keep several open tabs in sync.
  window.addEventListener("storage", function (event) {
    if (event.key === STORAGE_KEY) {
      tasks = loadTasks();
      render();
    } else if (event.key === CHECK_KEY) {
      check = loadCheck();
      renderCheck();
    }
  });

  verifyAfterReload();
  render();
  renderCheck();
})();
