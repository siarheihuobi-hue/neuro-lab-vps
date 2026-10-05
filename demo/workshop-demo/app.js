(function () {
  "use strict";

  var STORAGE_KEY = "workshop-demo.tasks.v1";

  var form = document.getElementById("add-form");
  var input = document.getElementById("task-input");
  var formError = document.getElementById("form-error");
  var list = document.getElementById("task-list");
  var emptyState = document.getElementById("empty-state");
  var counter = document.getElementById("counter");
  var clearDone = document.getElementById("clear-done");

  // localStorage can be unavailable (private mode, blocked storage): the app still works in memory.
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
    tasks.push({ id: newId(), text: text, done: false });
    saveTasks();
    render();
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
    render();
  });

  list.addEventListener("click", function (event) {
    if (!event.target.classList.contains("task__delete")) return;
    var id = event.target.closest(".task").dataset.id;
    tasks = tasks.filter(function (t) { return t.id !== id; });
    saveTasks();
    render();
  });

  clearDone.addEventListener("click", function () {
    tasks = tasks.filter(function (t) { return !t.done; });
    saveTasks();
    render();
  });

  // Keep several open tabs in sync.
  window.addEventListener("storage", function (event) {
    if (event.key === STORAGE_KEY) {
      tasks = loadTasks();
      render();
    }
  });

  render();
})();
