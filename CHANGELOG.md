# Changelog

[Русская версия ниже](#russian)

## 1.10

- Welcome tour on first launch: 8 animated pages. Gestures come first (three-finger press, shake, screen edge) with their toggles right on the page, then capture, markup, clipboard history and permissions. Skip, Back and Continue buttons, arrow keys, Esc and Return.
- The tour shows your own shortcuts from Settings, not the defaults.
- Only new installs see the tour. To open it again: "Welcome Tour…" in the Kadr menu or the button in Settings.
- On macOS 26 and later the window background is Liquid Glass; older systems get the standard system material. With Reduce Motion on, animations are replaced by a simple fade between pages.
- The tour frees its memory once closed.

## 1.9

- The three-finger press is now opt-in and off by default (Settings → History). If you had it on before, it stays on.
- If three-finger drag is on in the system (Accessibility → Pointer Control → Trackpad Options), Kadr no longer intercepts the press that starts it: the gesture yields to the system, and Settings shows a line about it. Before, Kadr swallowed that press and the drag broke.
- Kadr checks this setting every 3 s, so you can turn it on and off without restarting.

## 1.8

- Kadr uses less memory when idle: 16 MB after launch and about 33 MB after using the panels (was up to 90 MB, with a 170 MB peak).
- Clipboard history, the side panel and the text shelf free their memory 10 s after closing and are rebuilt when opened.
- Text recognition runs in a short-lived separate process, so the Vision models (~25 MB) no longer stay in memory. If that process fails to start, recognition runs the old way.
- Mouse tracking is on only when "Shake without dragging" is enabled.
- When idle, the clipboard is checked twice a second instead of four times.

## 1.7

- The three-finger press forgives uneven fingers. The third finger can touch down up to 100 ms before the click
  (if it is still resting) or up to 90 ms after it: Kadr waits for it.
- Fingers are counted from a short touch history, not a single frame. A finger that briefly flickers doesn't matter,
  and fingers that have already lifted (for example after a two-finger scroll) are not counted.
- If the third finger is late and macOS takes the press for a two-finger click (right-click), Kadr catches it too,
  and the context menu doesn't open. A normal two-finger click works as before, it just arrives up to 90 ms later.
- A resting thumb or the edge of your palm doesn't get in the way: three fingers plus a fourth contact still count as a press.
  Five or more contacts don't.
- The log gets one line per press with two or more fingers: button, fingers at the press and the maximum,
  how long Kadr waited for the third finger, when it touched down, and the decision.

## 1.6

- The interface is in English (the development language) and Russian: it follows the system language, and Settings
  lets you pick "System / English / Русский" (applies after restarting Kadr).
- The disk image now includes "How to open.txt" with instructions in English.

## 1.5

- A short soft "tick" on every new copy: from any app (passwords too), a screenshot to the clipboard, ⌘C in the editor,
  a click on a phrase on the text shelf, a copy by gesture. It stays silent for Kadr's own service writes (paste in sequence,
  restoring the clipboard) and while recording is paused; at most once every 120 ms.
- The sound is synthesized by our own script `tools/make_tick.swift` (36 ms, a 2.4 kHz tone with a 750 Hz body, −18 dBFS peak, no energy above 8 kHz).
- Settings → Clipboard History: "Sound on copy" (on by default), volume and "Preview".

## 1.4

- Clipboard history is shown as cards: source app icon, ⌘N number, time ("now", "5 min", "yesterday").
  - Links show the domain and address, images a thumbnail and size, files the name and folder.
  - Passwords show dots and an eye.
- ⌘1–⌘9 paste the card with that number. Numbers count from the first visible card.
- Bottom bar with no scrolling: search, History, Pinned and the "…" menu.
  - "…" holds the filters (text, links, images, files, passwords) and "Clear History…" with a confirmation.
- Typing starts a search right away. The first Esc closes the search, the second hides the panel.
- Dark and light themes with an even backdrop on any wallpaper.

## 1.3

- If text is selected in an app, a three-finger trackpad press copies it. A "Copied" hint appears next to the cursor.
- The selection is read through Accessibility. If the app doesn't respond, Kadr tries ⌘C and checks whether the clipboard changed.
- The gesture doesn't copy from password fields.
- Setting "Three-finger press on selected text copies it" (on by default).

## 1.2

- A three-finger trackpad press (before the click) opens and hides the history panel at the side of the screen.
  The press itself doesn't reach the app under the cursor.
- A panel opened by the gesture doesn't hide when you click outside it, so you can click into a field and paste into it from the panel.
- The screen-edge panel is now off by default. Both ways of opening the panel share the same side.
- If there is no trackpad or no access, the gesture quietly turns off, and ⌥⇧V works as before.

## 1.1

- History panel at the screen edge: it slides out when the cursor hits the edge.
  - It doesn't trigger at the seam between monitors, in corners, while dragging or over full-screen apps.
- A normal click pastes an entry. ⌘-click or ⇧-click selects several entries, and ↩ pastes them in sequence.

## 1.0

- Area, window and full-screen captures with ⌥⇧4/5/3. The capture goes straight to the clipboard and to `~/Pictures/Screenshots`.
- Markup editor: arrow, line, rectangle, oval, pen, highlighter, text, pixelate, numbering, crop.
- Pin a capture above all windows.
- Text recognition (Russian and English) from the screen (⌥⇧2) and from a capture.
- File shelf: opens when you shake the cursor while dragging, or with ⌥⇧D.
- Text shelf with saved phrases and paste in sequence (⌥⇧T).
- Clipboard history (⌥⇧V):
  - rich text, links, images and files;
  - search, filters, pinning;
  - pasting several entries with Tab.
- History is encrypted with AES-GCM, and the key is kept in the keychain. Passwords are hidden behind dots.
- Settings window: shortcuts, launch at login, menu bar icon, history rules.
- Isolated test profile (`KADR_PROFILE`) and command-line check modes.
- Zero network calls.

---

<a id="russian"></a>

# Изменения

## 1.10

- Знакомство при первом запуске: 8 экранов с анимацией. Сначала жесты (нажатие тремя пальцами, встряхивание, край экрана) с переключателями прямо на экране, потом снимок, разметка, история буфера, разрешения. Кнопки «Пропустить», «Назад», «Дальше», стрелки, Esc и Enter.
- Сочетания в туре берутся из настроек пользователя, а не заводские.
- Тур показывается только новым установкам. Открыть снова: «Welcome Tour…» в меню Kadr или кнопка в настройках.
- На macOS 26 и новее фон окна из Liquid Glass, на старых системах обычная системная подложка. При «Уменьшить движение» анимации заменяются плавной сменой экранов.
- После закрытия тур освобождает память.

## 1.9

- Нажатие тремя пальцами теперь по желанию и по умолчанию выключено (Настройки → История). Кто включал его раньше, у тех оно остаётся включённым.
- Если в системе включено перетаскивание тремя пальцами (Универсальный доступ → Управление указателем → Параметры трекпада), Kadr больше не перехватывает нажатие, с которого оно начинается: жест уступает системе, в настройках об этом есть строка. Раньше Kadr глотал это нажатие и перетаскивание ломалось.
- Kadr проверяет эту настройку раз в 3 с, так что её можно включать и выключать без перезапуска.

## 1.8

- Kadr в простое занимает меньше памяти: 16 МБ после запуска и около 33 МБ после работы с панелями (было до 90 МБ, пик 170 МБ).
- История буфера, боковая панель и полка текста освобождают память через 10 с после закрытия и строятся заново при открытии.
- Распознавание текста идёт в коротком отдельном процессе: модели Vision (~25 МБ) больше не висят в памяти. Если процесс не запустился, распознаём как раньше.
- Слежение за мышью включается, только если включено «встряхнуть без перетаскивания».
- В простое буфер обмена проверяется 2 раза в секунду вместо 4.

## 1.7

- Нажатие тремя пальцами прощает неровные пальцы. Третий палец может коснуться до 100 мс раньше щелчка
  (если ещё лежит) или до 90 мс позже: Kadr его подождёт.
- Пальцы считаются по короткой истории касаний, а не по одному кадру. Лёгкое «мигание» пальца не мешает,
  а пальцы, которые уже оторвались (например, после прокрутки двумя), не засчитываются.
- Если третий палец опоздал и macOS принял нажатие за щелчок двумя пальцами (правый щелчок), Kadr тоже его ловит,
  и контекстное меню не откроется. Обычный щелчок двумя пальцами работает как раньше, только приходит до 90 мс позже.
- Лежащий большой палец или край ладони не мешают: три пальца и четвёртый контакт тоже считаются нажатием.
  Пять контактов и больше — нет.
- В журнале на каждое нажатие двумя и более пальцами — одна строка: кнопка, пальцы при нажатии и максимум,
  сколько ждали третий палец, когда он коснулся, решение.

## 1.6

- Интерфейс на английском (язык разработки) и русском: язык следует за системой, в настройках можно выбрать
  «Системный / English / Русский» (применяется после перезапуска Kadr).
- В установочном образе появилась инструкция на английском «How to open.txt».

## 1.5

- Короткий мягкий «тик» при каждом новом копировании: из любой программы (и пароли), снимок в буфер, ⌘C в редакторе,
  щелчок по фразе на текстовой полке, копирование жестом. На служебные записи Kadr (вставка по очереди, возврат буфера)
  и на паузе записи не звучит; не чаще раза в 120 мс.
- Звук синтезирован своим скриптом `tools/make_tick.swift` (36 мс, тон 2,4 кГц и тело 750 Гц, пик −18 dBFS, без энергии выше 8 кГц).
- Настройки → «История буфера»: «Звук при копировании» (по умолчанию включён), громкость и «Прослушать».

## 1.4

- История буфера показана карточками: значок программы-источника, номер ⌘N, время («сейчас», «5 мин», «вчера»).
  - У ссылки видны домен и адрес, у картинки — миниатюра и размер, у файла — имя и папка.
  - У пароля — точки и глаз.
- ⌘1–⌘9 вставляют карточку с этим номером. Номера считаются от первой видимой карточки.
- Нижняя панель без прокрутки: поиск, «История», «Закреплённые» и меню «…».
  - В «…» — фильтры (текст, ссылки, картинки, файлы, пароли) и «Очистить историю…» с подтверждением.
- Печать сразу начинает поиск. Первый Esc закрывает поиск, второй прячет панель.
- Тёмная и светлая тема с ровной подложкой на любых обоях.

## 1.3

- Если в программе выделен текст, нажатие тачпада тремя пальцами копирует его. Рядом с курсором появляется подсказка
  «Скопировано».
- Выделение ищется через Accessibility. Если программа не отвечает, Kadr пробует ⌘C и проверяет, сменился ли буфер.
- Поле пароля жест не копирует.
- Настройка «Нажатие тремя пальцами при выделенном тексте — копировать» (по умолчанию включена).

## 1.2

- Нажатие тачпада тремя пальцами (до щелчка) открывает и прячет панель истории сбоку экрана. Само нажатие
  в программу под курсором не попадает.
- Панель, открытая жестом, не прячется от щелчка мимо. Можно щёлкнуть в поле и вставить в него из панели.
- Панель у края экрана теперь выключена по умолчанию. Сторона панели общая для обоих способов вызова.
- Если тачпада или доступа нет, жест тихо выключается, а ⌥⇧V работает как прежде.

## 1.1

- Панель истории у края экрана: выезжает, когда курсор упирается в край.
  - Не срабатывает на стыке мониторов, в углах, при перетаскивании и поверх полноэкранных программ.
- Обычный щелчок вставляет запись. ⌘-щелчок или ⇧-щелчок выделяет несколько записей, ↩ вставляет их по очереди.

## 1.0

- Снимки области, окна и экрана по сочетаниям ⌥⇧4/5/3. Снимок сразу в буфере и в `~/Pictures/Screenshots`.
- Редактор пометок: стрелка, линия, прямоугольник, овал, ручка, маркер, текст, мозаика, нумерация, обрезка.
- Закрепление снимка поверх окон.
- Распознавание текста (русский и английский) с экрана (⌥⇧2) и со снимка.
- Полка для файлов: открывается встряхиванием курсора при перетаскивании или по ⌥⇧D.
- Текстовая полка с постоянными фразами и вставкой по очереди (⌥⇧T).
- История буфера (⌥⇧V):
  - текст с оформлением, ссылки, картинки и файлы;
  - поиск, фильтры, закрепление;
  - вставка нескольких записей через Tab.
- История шифруется AES-GCM, ключ лежит в связке ключей. Пароли скрыты точками.
- Окно настроек: сочетания, автозапуск, значок в строке меню, правила истории.
- Изолированный тестовый профиль (`KADR_PROFILE`) и проверочные режимы командной строки.
- Ни одного сетевого вызова.
