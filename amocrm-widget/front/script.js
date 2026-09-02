define(['jquery', 'lib/components/base/modal'], function ($, Modal) {
  return function () {
    var self = this;
    var FRONT_VERSION = '1.16.0';
    var state = {
      leadPanelRendered: false,
      advancedReady: false,
      amoReady: false,
      workspaceModal: null,
      workspaceData: null,
      workspaceCellOptions: {},
      selectedSlot: null,
      bookingDuration: 30,
      showNonWorking: true,
      leadPreview: null,
      preparedBooking: null,
      bookingSubmitting: false,
      submittedTicketId: null,
      submittedStatus: null
    };

    this.callbacks = {
      init: function () {
        ensureWidgetStyles();
        return true;
      },

      render: function () {
        ensureWidgetStyles();
        renderLeadPanel();
        return true;
      },

      bind_actions: function () {
        bindLeadPanelActions();
        return true;
      },

      settings: function ($settingsBody) {
        ensureWidgetStyles();
        renderSettings($settingsBody);
        return true;
      },

      advancedSettings: function () {
        ensureWidgetStyles();
        renderAdvancedSettings(0);
        return true;
      },

      advanced_settings: function () {
        ensureWidgetStyles();
        renderAdvancedSettings(0);
        return true;
      },

      dpSettings: function () {
        return true;
      },

      onSave: function () {
        return true;
      },

      destroy: function () {
        $(document).off('.identWidget');
        if (state.workspaceModal && typeof state.workspaceModal.destroy === 'function') {
          state.workspaceModal.destroy();
        }
        $('.ident-widget-launcher, .ident-widget-workspace').remove();
        state.workspaceModal = null;
        return true;
      }
    };

    function getWidgetSettings() {
      if (typeof self.get_settings === 'function') return self.get_settings() || {};
      return {};
    }

    function ensureWidgetStyles() {
      var styleId = 'ident-amocrm-widget-styles';
      var existing = document.getElementById(styleId);
      if (existing) return;

      var settings = getWidgetSettings();
      var params = self.params || {};
      var widgetCode = settings.widget_code || params.widget_code || '';
      var basePath = trimSlash(params.path || '');
      if (!basePath && widgetCode) basePath = '/widgets/' + encodeURIComponent(widgetCode);
      if (!basePath) return;

      $('<link>', {
        id: styleId,
        rel: 'stylesheet',
        type: 'text/css',
        href: basePath + '/style.css?v=' + encodeURIComponent(FRONT_VERSION)
      }).appendTo(document.head || 'head');
    }

    function getConfig() {
      var settings = getWidgetSettings();
      var backendUrl = trimSlash(settings.backend_url || settings.BackendUrl || '');
      var serviceApiKey = $.trim(settings.service_api_key || settings.ServiceApiKey || '');
      return {
        backendUrl: backendUrl,
        serviceApiKey: serviceApiKey
      };
    }

    function renderSettings($settingsBody) {
      var $root = $settingsBody && $settingsBody.length ? $settingsBody : $('.widget_settings_block').first();
      if (!$root.length) return;
      if ($root.find('.ident-widget-settings').length) return;

      var html =
        '<div class="ident-widget-scope ident-widget-settings">' +
          '<div class="ident-widget-head">' +
            '<div class="ident-widget-title">IDENT amoCRM</div>' +
            '<div class="ident-widget-version">v' + escapeHtml(FRONT_VERSION) + '</div>' +
          '</div>' +
          '<div class="ident-widget-text">Укажите HTTPS URL сервиса и сервисный API-ключ.</div>' +
          '<div class="ident-widget-actions">' +
            '<button type="button" class="ident-widget-btn ident-widget-btn_secondary" data-ident-action="health">Проверить backend</button>' +
          '</div>' +
          '<div class="ident-widget-status" data-ident-settings-status>Настройки сохраняются штатными полями amoCRM.</div>' +
        '</div>';

      $root.append(html);
      $root.on('click.identSettings', '[data-ident-action="health"]', function () {
        runSettingsHealth($root);
      });
    }

    function renderLeadPanel() {
      if (state.leadPanelRendered || $('.ident-widget-launcher').length) return;
      if (!isLeadCard()) return;

      var html =
        '<div class="ident-widget-scope ident-widget-launcher">' +
          '<button type="button" class="ident-widget-launcher__button" data-ident-action="open_workspace">' +
            '<span class="ident-widget-launcher__mark">ID</span>' +
            '<span class="ident-widget-launcher__copy">' +
              '<strong>Открыть IDENT</strong>' +
              '<small>Расписание и запись</small>' +
            '</span>' +
            '<span class="ident-widget-launcher__arrow" aria-hidden="true">›</span>' +
          '</button>' +
        '</div>';

      if (typeof self.render_template === 'function') {
        self.render_template({
          body: '',
          caption: { class_name: 'ident-widget-caption' },
          render: html
        }, {});
      } else {
        var $host = findLeadHost();
        if (!$host.length) return;
        $host.prepend(html);
      }
      state.leadPanelRendered = true;
    }

    function bindLeadPanelActions() {
      $(document)
        .off('click.identWidget')
        .on('click.identWidget', '.ident-widget-launcher [data-ident-action], .ident-widget-workspace [data-ident-action]', function () {
          var action = $(this).attr('data-ident-action');
          if (action === 'open_workspace') openIdentWorkspace();
          if (action === 'refresh_schedule') loadWorkspaceSchedule();
          if (action === 'select_day') selectWorkspaceDay($(this).attr('data-ident-date'));
          if (action === 'select_slot') selectWorkspaceSlot($(this).attr('data-ident-slot-key'));
          if (action === 'set_duration') setWorkspaceDuration($(this).attr('data-ident-duration'));
          if (action === 'submit_booking') submitWorkspaceBooking();
          if (action === 'preview') previewCurrentLead();
        });

      $(document)
        .off('change.identWidget')
        .on('change.identWidget', '[data-ident-filter-doctor], [data-ident-filter-date], [data-ident-show-nonworking], [data-ident-duration-select]', function () {
          if ($(this).is('[data-ident-duration-select]')) {
            setWorkspaceDuration($(this).val());
            return;
          }
          if ($(this).is('[data-ident-show-nonworking]')) {
            state.showNonWorking = Boolean($(this).prop('checked'));
            renderWorkspaceSlots();
            return;
          }
          state.selectedSlot = null;
          resetWorkspaceSubmission();
          if ($(this).is('[data-ident-filter-doctor]')) {
            $('.ident-widget-workspace').last().find('[data-ident-filter-date]').val('');
          }
          renderWorkspaceSlots();
        });

      $(document)
        .off('input.identWidget')
        .on('input.identWidget', '[data-ident-booking-field]', function () {
          resetWorkspaceSubmission();
          updateWorkspaceReadiness($('.ident-widget-workspace').last());
        });
    }

    function openIdentWorkspace() {
      if ($('.ident-widget-workspace').length) return;

      state.workspaceData = null;
      state.workspaceCellOptions = {};
      state.selectedSlot = null;
      state.bookingDuration = 30;
      state.showNonWorking = true;
      state.leadPreview = null;
      state.preparedBooking = null;
      state.bookingSubmitting = false;
      state.submittedTicketId = null;
      state.submittedStatus = null;
      state.workspaceModal = new Modal({
        class_name: 'ident-widget-modal',
        container: document.body,
        disable_overlay_click: false,
        disable_escape_keydown: false,
        init_animation: false,
        centrify_animation: false,
        default_overlay: false,
        init: function ($modalBody) {
          $modalBody
            .addClass('ident-widget-modal__body')
            .html(buildWorkspaceHtml())
            .trigger('modal:loaded');
          centrifyWorkspaceModal($modalBody);
          loadWorkspaceSchedule($modalBody.find('.ident-widget-workspace'));
        },
        destroy: function () {
          state.workspaceModal = null;
          state.workspaceData = null;
          state.selectedSlot = null;
          state.leadPreview = null;
          state.preparedBooking = null;
          state.bookingSubmitting = false;
          state.submittedTicketId = null;
          state.submittedStatus = null;
        }
      });
    }

    function centrifyWorkspaceModal($modalBody) {
      var shell = findWorkspaceModalShell($modalBody);
      var container = findWorkspaceModalContainer(shell);
      var centrify = function () {
        if (!$modalBody || !$modalBody.length || !document.documentElement.contains($modalBody[0])) return;
        sizeWorkspaceModalShell(shell, container);
        $modalBody.trigger('modal:centrify');
      };

      centrify();
      if (typeof window.requestAnimationFrame === 'function') {
        window.requestAnimationFrame(centrify);
      }
      window.setTimeout(centrify, 60);
    }

    function findWorkspaceModalShell($modalBody) {
      if (!$modalBody || !$modalBody.length) return null;

      // amoCRM's Modal component always uses .modal-body for the window itself.
      // Do not infer it from dimensions: the overlay can temporarily have the
      // same narrow width while the right widgets panel is open.
      var $amoModalBody = $modalBody.closest('.modal-body');
      if ($amoModalBody.length) return $amoModalBody[0];

      return $modalBody[0].parentElement || $modalBody[0];
    }

    function findWorkspaceModalContainer(shell) {
      if (!shell) return document.documentElement;
      var shellWidth = shell.getBoundingClientRect().width;
      var node = shell.parentElement;

      while (node && node !== document.documentElement) {
        var rect = node.getBoundingClientRect();
        if (rect.width >= shellWidth + 32) return node;
        node = node.parentElement;
      }

      return document.documentElement;
    }

    function sizeWorkspaceModalShell(shell, container) {
      if (!shell) return;
      var containerWidth = container ? container.getBoundingClientRect().width : window.innerWidth;
      var availableWidth = Math.max(320, containerWidth || window.innerWidth);
      var width = Math.max(320, Math.min(1180, availableWidth - 64));

      shell.classList.add('ident-widget-modal-shell');
      shell.style.setProperty('background', '#ffffff', 'important');
      shell.style.setProperty('box-sizing', 'border-box', 'important');
      shell.style.setProperty('max-height', 'calc(100vh - 32px)', 'important');
      shell.style.setProperty('max-width', 'calc(100vw - 32px)', 'important');
      shell.style.setProperty('overflow', 'hidden', 'important');
      shell.style.setProperty('padding', '0', 'important');
      shell.style.setProperty('width', width + 'px', 'important');
    }

    function buildWorkspaceHtml() {
      var leadId = getCurrentLeadId();
      return '<div class="ident-widget-scope ident-widget-workspace">' +
        '<div class="ident-widget-workspace__head">' +
          '<div>' +
            '<div class="ident-widget-workspace__eyebrow">IDENT</div>' +
            '<div class="ident-widget-workspace__title">Расписание и запись</div>' +
          '</div>' +
          '<div class="ident-widget-workspace__meta">Сделка #' + escapeHtml(leadId || 'не определена') + ' · v' + escapeHtml(FRONT_VERSION) + '</div>' +
        '</div>' +
        '<div class="ident-widget-workspace__metrics" data-ident-workspace-metrics>' +
          workspaceMetric('Врачи', '—') +
          workspaceMetric('Свободно', '—') +
          workspaceMetric('Занято', '—') +
          workspaceMetric('Филиал', '—') +
          workspaceMetric('Обновлено', '—') +
        '</div>' +
        '<div class="ident-widget-workspace__toolbar">' +
          '<label class="ident-widget-workspace__field">' +
            '<span>Врач</span>' +
            '<select data-ident-filter-doctor><option value="">Все врачи</option></select>' +
          '</label>' +
          '<label class="ident-widget-workspace__field">' +
            '<span>Дата</span>' +
            '<input type="date" data-ident-filter-date>' +
          '</label>' +
          '<button type="button" class="ident-widget-btn ident-widget-btn_secondary ident-widget-workspace__refresh" data-ident-action="refresh_schedule">Обновить</button>' +
        '</div>' +
        '<div class="ident-widget-workspace__layout">' +
          '<section class="ident-widget-workspace__schedule">' +
            '<div class="ident-widget-workspace__section-head">' +
              '<strong>Расписание по врачам</strong>' +
              '<span data-ident-workspace-count>загрузка</span>' +
            '</div>' +
            '<div class="ident-widget-workspace__days" data-ident-workspace-days></div>' +
            '<div class="ident-widget-workspace__legend">' +
              '<span><i class="ident-widget-workspace__legend-dot ident-widget-workspace__legend-dot_free"></i>Свободно</span>' +
              '<span><i class="ident-widget-workspace__legend-dot ident-widget-workspace__legend-dot_busy"></i>Занято</span>' +
              '<span><i class="ident-widget-workspace__legend-dot ident-widget-workspace__legend-dot_reserved"></i>Резерв</span>' +
              '<span><i class="ident-widget-workspace__legend-dot ident-widget-workspace__legend-dot_off"></i>Нерабочее</span>' +
              '<div class="ident-widget-workspace__view-controls">' +
                '<label class="ident-widget-workspace__duration">' +
                  '<span>Длительность</span>' +
                  '<select data-ident-duration-select aria-label="Длительность записи">' +
                    workspaceDurationOptions() +
                  '</select>' +
                '</label>' +
                '<label class="ident-widget-workspace__off-toggle">' +
                  '<input type="checkbox" data-ident-show-nonworking checked>' +
                  '<span>Нерабочее время</span>' +
                '</label>' +
              '</div>' +
            '</div>' +
            '<div class="ident-widget-workspace__slots" data-ident-workspace-slots>' +
              '<div class="ident-widget-empty">Загружаю расписание...</div>' +
            '</div>' +
          '</section>' +
          '<aside class="ident-widget-workspace__selection">' +
            '<div class="ident-widget-workspace__section-head">' +
              '<strong>Новая запись</strong>' +
              '<span class="ident-widget-workspace__draft-state" data-ident-booking-state>черновик</span>' +
            '</div>' +
            '<div class="ident-widget-workspace__selected" data-ident-workspace-selection>' +
              '<div class="ident-widget-empty">Сначала выберите свободное окно.</div>' +
            '</div>' +
            '<div class="ident-widget-workspace__form-section">' +
              '<div class="ident-widget-workspace__form-title">Пациент <span data-ident-patient-source>из сделки amoCRM</span></div>' +
              '<label class="ident-widget-workspace__form-field">' +
                '<span>ФИО *</span>' +
                '<input type="text" autocomplete="off" data-ident-booking-field="fullName" placeholder="Фамилия Имя Отчество">' +
              '</label>' +
              '<div class="ident-widget-workspace__form-grid">' +
                '<label class="ident-widget-workspace__form-field">' +
                  '<span>Телефон *</span>' +
                  '<input type="tel" autocomplete="off" data-ident-booking-field="phone" placeholder="+7 999 000-00-00">' +
                '</label>' +
                '<label class="ident-widget-workspace__form-field">' +
                  '<span>Email</span>' +
                  '<input type="email" autocomplete="off" data-ident-booking-field="email" placeholder="patient@example.ru">' +
                '</label>' +
              '</div>' +
            '</div>' +
            '<label class="ident-widget-workspace__form-field ident-widget-workspace__form-field_comment">' +
              '<span>Комментарий</span>' +
              '<textarea rows="5" data-ident-booking-field="comment" placeholder="Пожелания пациента или примечание для администратора"></textarea>' +
            '</label>' +
            '<div class="ident-widget-workspace__readiness" data-ident-booking-readiness></div>' +
            '<div class="ident-widget-workspace__actions">' +
              '<button type="button" class="ident-widget-btn ident-widget-btn_secondary" data-ident-action="preview" data-ident-requires-amo disabled>Заполнить из сделки</button>' +
              '<button type="button" class="ident-widget-btn" data-ident-action="submit_booking" disabled>Создать заявку в IDENT</button>' +
            '</div>' +
            '<div class="ident-widget-workspace__action-note">Будет создана заявка на выбранное время. Подтверждение приема выполняет IDENT.</div>' +
            '<div class="ident-widget-status" data-ident-status>Подключаюсь к IDENT...</div>' +
          '</aside>' +
        '</div>' +
      '</div>';
    }

    function workspaceMetric(label, value) {
      return '<div class="ident-widget-workspace__metric"><span>' + escapeHtml(label) + '</span><strong>' + escapeHtml(value) + '</strong></div>';
    }

    function loadWorkspaceSchedule($workspace) {
      var $root = $workspace && $workspace.length ? $workspace : $('.ident-widget-workspace').last();
      if (!$root.length) return;

      $root.find('[data-ident-workspace-slots]').html('<div class="ident-widget-empty">Обновляю расписание...</div>');
      Promise.all([
        safeApiRequest('/api/timetable'),
        safeApiRequest('/health')
      ]).then(function (results) {
        var slotsResult = results[0];
        var healthResult = results[1];
        if (!slotsResult.ok) throw new Error(slotsResult.error || 'Расписание пока не загружено.');

        state.workspaceData = slotsResult.data;
        state.selectedSlot = null;
        state.workspaceCellOptions = {};
        state.preparedBooking = null;
        state.bookingSubmitting = false;
        state.submittedTicketId = null;
        state.submittedStatus = null;
        state.amoReady = Boolean(healthResult.ok && healthResult.data.amoConfigured);
        $root.find('[data-ident-requires-amo]').prop('disabled', !state.amoReady);
        renderWorkspaceDoctorFilter($root);
        renderWorkspaceMetrics($root);
        renderWorkspaceSlots();
        updateWorkspaceReadiness($root);
        setLeadStatus(
          state.amoReady
            ? 'Расписание загружено.'
            : 'Расписание доступно. Данные пациента можно заполнить вручную.',
          state.amoReady ? 'ok' : 'warn'
        );
        if (state.amoReady) loadWorkspaceLeadPreview($root);
      }).catch(function (error) {
        $root.find('[data-ident-workspace-slots]').html('<div class="ident-widget-empty">Расписание недоступно.</div>');
        setLeadStatus(error.message, 'error');
      });
    }

    function renderWorkspaceDoctorFilter($root) {
      var $select = $root.find('[data-ident-filter-doctor]');
      var selected = String($select.val() || '');
      var options = (state.workspaceData.Doctors || []).map(function (doctor) {
        return '<option value="' + escapeHtml(doctor.Id) + '">' + escapeHtml(doctor.Name) + '</option>';
      }).join('');
      $select.html('<option value="">Все врачи</option>' + options).val(selected);
    }

    function renderWorkspaceMetrics($root) {
      var data = state.workspaceData || {};
      var intervals = futureScheduleSlots(data.Intervals || []);
      var freeCount = intervals.filter(function (item) { return !item.IsBusy; }).length;
      var busyCount = intervals.length - freeCount;
      var branches = data.Branches || [];
      $root.find('[data-ident-workspace-metrics]').html(
        workspaceMetric('Врачи', (data.Doctors || []).length) +
        workspaceMetric('Свободно', freeCount) +
        workspaceMetric('Занято', busyCount) +
        workspaceMetric('Филиал', branches.length === 1 ? branches[0].Name : branches.length) +
        workspaceMetric('Обновлено', formatWorkspaceUpdatedAt(data.receivedAt))
      );
    }

    function renderWorkspaceSlots() {
      var $root = $('.ident-widget-workspace').last();
      if (!$root.length || !state.workspaceData) return;

      var doctorId = String($root.find('[data-ident-filter-doctor]').val() || '');
      var date = String($root.find('[data-ident-filter-date]').val() || '');
      var doctors = mapById(state.workspaceData.Doctors || []);
      var branches = mapById(state.workspaceData.Branches || []);
      var allIntervals = futureScheduleSlots(state.workspaceData.Intervals || []);
      var doctorIntervals = allIntervals.filter(function (item) {
        return !doctorId || String(item.DoctorId) === doctorId;
      });

      if (!date && doctorIntervals.length) {
        date = slotDateValue(doctorIntervals[0].StartDateTime);
        $root.find('[data-ident-filter-date]').val(date);
      }

      renderWorkspaceDays($root, doctorIntervals, date);
      var intervals = doctorIntervals.filter(function (item) {
        return !date || slotDateValue(item.StartDateTime) === date;
      });

      if (state.selectedSlot && (
        (doctorId && String(state.selectedSlot.DoctorId) !== doctorId) ||
        (date && slotDateValue(state.selectedSlot.StartDateTime) !== date)
      )) {
        state.selectedSlot = null;
        resetWorkspaceSubmission();
      }

      var visibleDoctors = (state.workspaceData.Doctors || []).filter(function (doctor) {
        return !doctorId || String(doctor.Id) === doctorId;
      }).sort(function (left, right) {
        return String(left.Name || '').localeCompare(String(right.Name || ''), 'ru');
      });
      var grid = buildWorkspaceTimeline(date, visibleDoctors, intervals);
      state.workspaceCellOptions = {};
      grid.cells.forEach(function (cell) {
        state.workspaceCellOptions[cell.key] = workspaceSelectionForCell(cell, grid.cellMap, state.bookingDuration);
      });

      var selectedKeys = state.selectedSlot && Array.isArray(state.selectedSlot.CoveredSlotKeys)
        ? state.selectedSlot.CoveredSlotKeys
        : [];
      var header = '<div class="ident-widget-workspace-timeline__row ident-widget-workspace-timeline__head">' +
        '<div class="ident-widget-workspace-timeline__time">Время</div>' +
        visibleDoctors.map(function (doctor) {
          var doctorCells = grid.cells.filter(function (cell) { return String(cell.doctorId) === String(doctor.Id); });
          var freeCount = doctorCells.filter(function (cell) { return cell.status === 'free'; }).length;
          return '<div class="ident-widget-workspace-timeline__doctor" title="' + escapeHtml(doctor.Name) + '">' +
            '<strong>' + escapeHtml(compactDoctorName(doctor.Name)) + '</strong><small>' + freeCount + ' свободно</small>' +
          '</div>';
        }).join('') +
      '</div>';
      var visibleRows = 0;
      var rows = grid.rows.map(function (row) {
        var allOff = row.cells.every(function (cell) { return cell.status === 'off'; });
        if (!state.showNonWorking && allOff) return '';
        visibleRows += 1;
        return '<div class="ident-widget-workspace-timeline__row' + (row.minute % 30 === 0 ? ' is-major' : '') + '">' +
          '<div class="ident-widget-workspace-timeline__time">' + escapeHtml(row.label) + '</div>' +
          row.cells.map(function (cell) {
            return renderWorkspaceTimelineCell(cell, state.workspaceCellOptions[cell.key], selectedKeys, doctors, branches);
          }).join('') +
        '</div>';
      }).join('');
      var timeline = visibleDoctors.length && date
        ? '<div class="ident-widget-workspace-timeline-scroll"><div class="ident-widget-workspace-timeline" style="--ident-doctor-count:' + visibleDoctors.length + '">' +
            header + (rows || '<div class="ident-widget-empty">Нет рабочих или занятых интервалов.</div>') +
          '</div></div>'
        : '<div class="ident-widget-empty">На выбранную дату расписание не найдено.</div>';
      var freeTotal = grid.cells.filter(function (cell) { return cell.status === 'free'; }).length;
      var busyTotal = grid.cells.filter(function (cell) { return cell.status === 'busy'; }).length;

      $root.find('[data-ident-duration-select]').val(String(state.bookingDuration));
      $root.find('[data-ident-show-nonworking]').prop('checked', state.showNonWorking);
      $root.find('[data-ident-workspace-count]').text(
        date ? freeTotal + ' свободно · ' + busyTotal + ' занято · ' + visibleRows + ' строк' : 'нет интервалов'
      );
      $root.find('[data-ident-workspace-slots]').html(timeline);
      renderWorkspaceSelection($root, doctors, branches);
    }

    function buildWorkspaceTimeline(date, doctors, intervals) {
      var rows = [];
      var cells = [];
      var cellMap = {};
      if (!date) return { rows: rows, cells: cells, cellMap: cellMap };

      for (var minute = 9 * 60; minute < 22 * 60; minute += 15) {
        var timestamp = workspaceDayTimestamp(date, minute);
        var row = { minute: minute, label: workspaceMinuteLabel(minute), cells: [] };
        doctors.forEach(function (doctor) {
          var cell = buildWorkspaceTimelineCell(doctor, timestamp, intervals);
          row.cells.push(cell);
          cells.push(cell);
          cellMap[cell.key] = cell;
        });
        rows.push(row);
      }
      return { rows: rows, cells: cells, cellMap: cellMap };
    }

    function buildWorkspaceTimelineCell(doctor, timestamp, intervals) {
      var matches = intervals.filter(function (item) {
        return String(item.DoctorId) === String(doctor.Id) && workspaceIntervalCovers(item, timestamp);
      });
      var busy = matches.filter(function (item) { return Boolean(item.IsBusy); });
      var free = matches.filter(function (item) { return !item.IsBusy; });
      return {
        key: workspaceTimelineCellKey(doctor.Id, timestamp),
        doctorId: doctor.Id,
        timestamp: timestamp,
        status: busy.length ? 'busy' : free.length ? 'free' : 'off',
        reserved: busy.some(function (item) { return Boolean(item.IsReserved); }),
        freeIntervals: busy.length ? [] : free
      };
    }

    function workspaceIntervalCovers(interval, timestamp) {
      var start = slotTimestamp(interval.StartDateTime);
      var duration = Math.max(15, Number(interval.LengthInMinutes) || 15);
      return Number.isFinite(start) && start <= timestamp && start + duration * 60000 > timestamp;
    }

    function workspaceSelectionForCell(cell, cellMap, duration) {
      if (!cell || cell.status !== 'free' || !cell.freeIntervals.length || cell.timestamp < Date.now() - 60000) return null;
      var covered = [cell];
      var segmentCount = Math.max(1, Math.floor(Number(duration) / 15));
      for (var index = 1; index < segmentCount; index += 1) {
        var next = cellMap[workspaceTimelineCellKey(cell.doctorId, cell.timestamp + index * 15 * 60000)];
        if (!next || next.status !== 'free') return null;
        covered.push(next);
      }

      var branchMatch = cell.freeIntervals.find(function (first) {
        return covered.every(function (coveredCell) {
          return coveredCell.freeIntervals.some(function (item) {
            return String(item.BranchId) === String(first.BranchId);
          });
        });
      });
      if (!branchMatch) return null;

      return {
        StartDateTime: workspaceDateTimeValue(cell.timestamp),
        LengthInMinutes: duration,
        DoctorId: branchMatch.DoctorId,
        BranchId: branchMatch.BranchId,
        IsBusy: false,
        CoveredSlotKeys: covered.map(function (coveredCell) { return coveredCell.key; })
      };
    }

    function renderWorkspaceTimelineCell(cell, selection, selectedKeys, doctors, branches) {
      var selected = selectedKeys.indexOf(cell.key) !== -1;
      var doctorName = nameById(doctors, cell.doctorId, 'Врач ' + cell.doctorId);
      var label = formatSlotTime(workspaceDateTimeValue(cell.timestamp));
      if (cell.status === 'busy') {
        return '<div class="ident-widget-workspace-timeline__cell ' + (cell.reserved ? 'is-reserved' : 'is-busy') + '" title="' +
          escapeHtml(label + (cell.reserved ? ' · зарезервировано · ' : ' · занято · ') + doctorName) + '"><span>' +
          (cell.reserved ? 'Резерв' : 'Занято') + '</span></div>';
      }
      if (cell.status === 'off') {
        return '<div class="ident-widget-workspace-timeline__cell is-off" title="' +
          escapeHtml(label + ' · нерабочее время · ' + doctorName) + '"><span>Не работает</span></div>';
      }

      var branchName = selection ? nameById(branches, selection.BranchId, 'Филиал') : '';
      return '<button type="button" class="ident-widget-workspace-timeline__cell is-free' + (selected ? ' is-selected' : '') + '" ' +
        'data-ident-action="select_slot" data-ident-slot-key="' + escapeHtml(cell.key) + '" ' +
        'aria-pressed="' + (selected ? 'true' : 'false') + '" ' + (selection ? '' : 'disabled ') +
        'title="' + escapeHtml(selection
          ? label + ' · свободно · ' + doctorName + ' · ' + branchName + ' · ' + state.bookingDuration + ' мин'
          : label + ' · недостаточно свободного времени') + '">' +
        '<span>' + (selection ? 'Свободно' : 'Недоступно') + '</span>' +
      '</button>';
    }

    function workspaceTimelineCellKey(doctorId, timestamp) {
      return String(doctorId) + '|' + String(timestamp);
    }

    function workspaceDayTimestamp(date, minute) {
      var hours = Math.floor(minute / 60);
      var minutes = minute % 60;
      return slotTimestamp(date + 'T' + padTwo(hours) + ':' + padTwo(minutes) + ':00');
    }

    function workspaceMinuteLabel(minute) {
      return padTwo(Math.floor(minute / 60)) + ':' + padTwo(minute % 60);
    }

    function workspaceDateTimeValue(timestamp) {
      var value = new Date(timestamp);
      return value.getFullYear() + '-' + padTwo(value.getMonth() + 1) + '-' + padTwo(value.getDate()) + 'T' +
        padTwo(value.getHours()) + ':' + padTwo(value.getMinutes()) + ':00';
    }

    function padTwo(value) {
      return String(value).padStart(2, '0');
    }

    function compactDoctorName(value) {
      var parts = String(value || '').trim().split(/\s+/).filter(Boolean);
      if (parts.length < 2) return parts.join(' ');
      return parts[0] + ' ' + parts.slice(1).map(function (part) { return part.charAt(0) + '.'; }).join(' ');
    }

    function renderWorkspaceDays($root, intervals, selectedDate) {
      var dates = [];
      var dateCounts = {};
      intervals.forEach(function (item) {
        var value = slotDateValue(item.StartDateTime);
        if (!dateCounts[value]) {
          dateCounts[value] = { free: 0, busy: 0 };
          dates.push(value);
        }
        dateCounts[value][item.IsBusy ? 'busy' : 'free'] += 1;
      });
      dates.sort();

      var selectedIndex = Math.max(0, dates.indexOf(selectedDate));
      var start = Math.max(0, Math.min(selectedIndex - 2, Math.max(0, dates.length - 7)));
      var visibleDates = dates.slice(start, start + 7);
      var html = visibleDates.map(function (value) {
        var counts = dateCounts[value];
        var selected = value === selectedDate;
        return '<button type="button" class="ident-widget-workspace-day' + (selected ? ' ident-widget-workspace-day_selected' : '') + '" ' +
          'data-ident-action="select_day" data-ident-date="' + escapeHtml(value) + '" aria-pressed="' + (selected ? 'true' : 'false') + '">' +
          '<span>' + escapeHtml(formatDayWeekday(value)) + '</span>' +
          '<strong>' + escapeHtml(formatDayShort(value)) + '</strong>' +
          '<small><b>' + counts.free + '</b> / ' + counts.busy + '</small>' +
        '</button>';
      }).join('');
      $root.find('[data-ident-workspace-days]').html(html);
    }

    function selectWorkspaceDay(date) {
      var $root = $('.ident-widget-workspace').last();
      if (!$root.length || !date) return;
      state.selectedSlot = null;
      resetWorkspaceSubmission();
      $root.find('[data-ident-filter-date]').val(date);
      renderWorkspaceSlots();
    }

    function selectWorkspaceSlot(key) {
      if (!state.workspaceData || !state.workspaceCellOptions[key]) return;
      state.selectedSlot = state.workspaceCellOptions[key];
      resetWorkspaceSubmission();
      renderWorkspaceSlots();
    }

    function setWorkspaceDuration(value) {
      var duration = Number.parseInt(String(value), 10);
      if (!Number.isInteger(duration) || duration < 15 || duration > 720 || duration % 15 !== 0) return;
      if (duration === state.bookingDuration) return;
      state.bookingDuration = duration;
      state.selectedSlot = null;
      resetWorkspaceSubmission();
      renderWorkspaceSlots();
    }

    function workspaceDurationOptions() {
      var options = [];
      for (var duration = 15; duration <= 720; duration += 15) {
        options.push(
          '<option value="' + duration + '"' + (duration === 30 ? ' selected' : '') + '>' +
            escapeHtml(formatWorkspaceDuration(duration)) +
          '</option>'
        );
      }
      return options.join('');
    }

    function formatWorkspaceDuration(value) {
      var duration = Number(value) || 15;
      if (duration < 60) return duration + ' мин';
      var hours = Math.floor(duration / 60);
      var minutes = duration % 60;
      return hours + ' ч' + (minutes ? ' ' + minutes + ' мин' : '');
    }

    function renderWorkspaceSelection($root, doctors, branches) {
      var $selection = $root.find('[data-ident-workspace-selection]');
      if (!state.selectedSlot) {
        $selection.html('<div class="ident-widget-empty">Сначала выберите свободное окно.</div>');
        updateWorkspaceReadiness($root);
        return;
      }
      var slot = state.selectedSlot;
      $selection.html(
        '<div class="ident-widget-workspace__selected-time">' + escapeHtml(formatSlotDateTime(slot.StartDateTime)) + '</div>' +
        '<div class="ident-widget-workspace__selected-doctor">' + escapeHtml(nameById(doctors, slot.DoctorId, 'Врач ' + slot.DoctorId)) + '</div>' +
        '<div class="ident-widget-workspace__selected-meta">' +
          escapeHtml(nameById(branches, slot.BranchId, 'Филиал')) + ' · ' + escapeHtml(formatWorkspaceDuration(slot.LengthInMinutes || 15)) +
        '</div>'
      );
      updateWorkspaceReadiness($root);
    }

    function futureFreeSlots(intervals) {
      return futureScheduleSlots(intervals).filter(function (item) {
        return !item.IsBusy;
      });
    }

    function futureScheduleSlots(intervals) {
      return (intervals || []).filter(function (item) {
        return isFutureSlot(item.StartDateTime);
      }).sort(function (left, right) {
        return slotTimestamp(left.StartDateTime) - slotTimestamp(right.StartDateTime);
      });
    }

    function workspaceSlotKey(item) {
      return String(item.DoctorId) + '|' + String(item.BranchId) + '|' + String(item.StartDateTime);
    }

    function slotDateValue(value) {
      return String(value || '').slice(0, 10);
    }

    function formatWorkspaceUpdatedAt(value) {
      var timestamp = slotTimestamp(value);
      if (!Number.isFinite(timestamp)) return '—';
      return new Intl.DateTimeFormat('ru-RU', { hour: '2-digit', minute: '2-digit' }).format(new Date(timestamp));
    }

    function formatSlotTime(value) {
      var timestamp = slotTimestamp(value);
      if (!Number.isFinite(timestamp)) return '—';
      return new Intl.DateTimeFormat('ru-RU', { hour: '2-digit', minute: '2-digit' }).format(new Date(timestamp));
    }

    function formatDayWeekday(value) {
      var timestamp = slotTimestamp(String(value) + 'T00:00:00');
      if (!Number.isFinite(timestamp)) return '';
      return new Intl.DateTimeFormat('ru-RU', { weekday: 'short' }).format(new Date(timestamp)).replace('.', '');
    }

    function formatDayShort(value) {
      var timestamp = slotTimestamp(String(value) + 'T00:00:00');
      if (!Number.isFinite(timestamp)) return value;
      return new Intl.DateTimeFormat('ru-RU', { day: 'numeric', month: 'short' }).format(new Date(timestamp)).replace('.', '');
    }

    function isFutureSlot(value) {
      var timestamp = slotTimestamp(value);
      return Number.isFinite(timestamp) && timestamp >= Date.now() - 60000;
    }

    function slotTimestamp(value) {
      if (!value) return Number.NaN;
      var timestamp = new Date(String(value)).getTime();
      return Number.isFinite(timestamp) ? timestamp : Number.NaN;
    }

    function formatSlotDateTime(value) {
      var timestamp = slotTimestamp(value);
      if (!Number.isFinite(timestamp)) return formatDateTime(value);
      return new Intl.DateTimeFormat('ru-RU', {
        weekday: 'short',
        day: '2-digit',
        month: '2-digit',
        hour: '2-digit',
        minute: '2-digit'
      }).format(new Date(timestamp));
    }

    function renderAdvancedSettings(attempt) {
      var $holder = $('#list_page_holder');
      if (!$holder.length && attempt < 30) {
        window.setTimeout(function () {
          renderAdvancedSettings(attempt + 1);
        }, 100);
        return;
      }

      var $root = $holder.length ? $holder : $('body');
      if (state.advancedReady && $root.find('.ident-widget-advanced').length) return;
      state.advancedReady = true;

      var config = getConfig();
      var html =
        '<div class="ident-widget-scope ident-widget-advanced">' +
          '<div class="ident-widget-head">' +
            '<div>' +
              '<div class="ident-widget-title">IDENT amoCRM</div>' +
              '<div class="ident-widget-text">Настройка подключения, полей, статусов, вебхуков и врачей.</div>' +
            '</div>' +
            '<div class="ident-widget-version">v' + escapeHtml(FRONT_VERSION) + '</div>' +
          '</div>' +
          '<div class="ident-widget-readiness">' +
            '<div class="ident-widget-card__title">Готовность запуска</div>' +
            '<div class="ident-widget-metrics" data-ident-readiness-metrics>' +
              readinessMetric('Сервис', 'проверка', '') +
              readinessMetric('amoCRM', 'проверка', '') +
              readinessMetric('Агент', 'проверка', '') +
              readinessMetric('Расписание', 'проверка', '') +
            '</div>' +
            '<div class="ident-widget-card__text" data-ident-readiness-note>Проверяю подключение и последние данные...</div>' +
          '</div>' +
          '<div class="ident-widget-grid">' +
            advancedCard('backend', 'Сервис', 'Проверка доступности backend и общей готовности интеграции.', [
              button('health', 'Проверить сервис', 'secondary'),
              button('diagnostics', 'Диагностика', 'secondary')
            ]) +
            advancedCard('amocrm', 'amoCRM', 'OAuth, схема аккаунта, поля, статусы и вебхуки.', [
              button('schema', 'Схема amoCRM', 'secondary'),
              button('oauth', 'Авторизовать amoCRM', 'secondary'),
              button('webhooks', 'Зарегистрировать вебхуки', ''),
              button('bootstrap', 'Создать поля и статусы', '')
            ]) +
            advancedCard('runtime', 'Настройки', 'Runtime-поля amoCRM, статусы обратной связи и контроль дублей.', [
              button('settings', 'Загрузить настройки', 'secondary'),
              button('save_settings', 'Сохранить настройки', '')
            ]) +
            advancedCard('mappings', 'Врачи', 'Соответствие врачей IDENT, ID amoCRM и алиасов.', [
              button('mappings', 'Загрузить врачей', 'secondary'),
              button('save_mappings', 'Сохранить врачей', '')
            ]) +
            advancedCard('schedule', 'Расписание IDENT', 'Просмотр врачей, филиалов, свободных окон и ручной sync в amoCRM.', [
              button('timetable', 'Все расписание', 'secondary'),
              button('free_slots', 'Свободные окна', 'secondary'),
              button('sync_timetable', 'Передать в amoCRM', '')
            ]) +
            advancedCard('agent', 'Компьютер клиники', 'Состояние Windows-агента, последняя выгрузка и управление роботом заявок.', [
              button('agent_status', 'Обновить состояние', 'secondary'),
              button('agent_schema', 'Структура БД', 'secondary')
            ]) +
            advancedCard('identdb', 'База IDENT', 'Read-only подключение к базе IDENT: схема, SQL-маппинг и синхронизация расписания.', [
              button('db_status', 'Статус БД', 'secondary'),
              button('db_schema', 'Таблицы и поля', 'secondary'),
              button('db_preview', 'Preview расписания', 'secondary'),
              button('db_sync', 'Синхронизировать из БД', '')
            ]) +
          '</div>' +
          '<div class="ident-widget-card">' +
            '<div class="ident-widget-card__title">Агент клиники и робот заявок</div>' +
            '<div class="ident-widget-card__text">Агент запускается вместе с Windows, отправляет расписание и отдельно управляет роботом подтверждения заявок.</div>' +
            '<div class="ident-widget-schedule" data-ident-agent-summary>Загружаю состояние агента...</div>' +
            '<div class="ident-widget-switches">' +
              '<label class="ident-widget-switch">' +
                '<input type="checkbox" data-ident-agent-schedule>' +
                '<span>Выгрузка расписания</span>' +
              '</label>' +
              '<label class="ident-widget-switch">' +
                '<input type="checkbox" data-ident-agent-robot>' +
                '<span>Робот подтверждения заявок</span>' +
              '</label>' +
            '</div>' +
            '<div class="ident-widget-actions ident-widget-actions_spaced">' +
              button('save_agent', 'Сохранить переключатели', '') +
            '</div>' +
            '<div class="ident-widget-section">' +
              '<div class="ident-widget-card__title">Удаленная настройка расписания</div>' +
              '<div class="ident-widget-card__text">Структура содержит только названия таблиц и колонок. После проверки сохраните четыре read-only SELECT-запроса, агент применит их при следующем сигнале.</div>' +
              '<div class="ident-widget-schedule" data-ident-agent-schema-summary>Структура БД еще не загружена.</div>' +
              '<textarea class="ident-widget-editor ident-widget-editor_tall" data-ident-agent-schema-json readonly></textarea>' +
              '<div class="ident-widget-actions ident-widget-actions_spaced">' +
                button('agent_schema', 'Загрузить структуру БД', 'secondary') +
              '</div>' +
              '<textarea class="ident-widget-editor ident-widget-editor_tall ident-widget-editor_spaced" data-ident-agent-mapping-json></textarea>' +
              '<div class="ident-widget-actions ident-widget-actions_spaced">' +
                button('save_agent_mapping', 'Передать SQL-маппинг агенту', '') +
              '</div>' +
            '</div>' +
          '</div>' +
          '<div class="ident-widget-card">' +
            '<div class="ident-widget-card__title">Read-only база IDENT</div>' +
            '<div class="ident-widget-card__text">Сначала проверьте подключение и схему, затем заполните SELECT-запросы для врачей, филиалов, расписания и услуг.</div>' +
            '<div class="ident-widget-schedule" data-ident-db-summary>Статус БД еще не проверен.</div>' +
            '<textarea class="ident-widget-editor ident-widget-editor_tall" data-ident-db-json></textarea>' +
            '<div class="ident-widget-actions ident-widget-actions_spaced">' +
              button('db_mapping', 'Загрузить SQL-маппинг', 'secondary') +
              button('save_db_mapping', 'Сохранить SQL-маппинг', '') +
            '</div>' +
          '</div>' +
          '<div class="ident-widget-card">' +
            '<div class="ident-widget-card__title">Расписание, врачи и свободные окна</div>' +
            '<div class="ident-widget-card__text">После первого PostTimeTable здесь видно, что IDENT реально отдал в интеграцию.</div>' +
            '<div class="ident-widget-schedule" data-ident-schedule-summary>Расписание еще не загружено.</div>' +
            '<textarea class="ident-widget-editor ident-widget-editor_tall" data-ident-schedule-json></textarea>' +
          '</div>' +
          '<div class="ident-widget-card">' +
            '<div class="ident-widget-card__title">Тестовая запись в amoCRM</div>' +
            '<div class="ident-widget-card__text">Сначала создается сделка в amoCRM, затем заявка ставится в очередь IDENT. Без авторизации amoCRM отправка заблокирована.</div>' +
            '<textarea class="ident-widget-editor" data-ident-booking-json></textarea>' +
            '<div class="ident-widget-actions ident-widget-actions_spaced">' +
              button('create_booking', 'Создать тестовую запись', '') +
            '</div>' +
          '</div>' +
          '<div class="ident-widget-card">' +
            '<div class="ident-widget-card__title">Runtime settings JSON</div>' +
            '<div class="ident-widget-card__text">Для точечной настройки ID полей, статусов и параметров дублей.</div>' +
            '<textarea class="ident-widget-editor" data-ident-settings-json></textarea>' +
          '</div>' +
          '<div class="ident-widget-card">' +
            '<div class="ident-widget-card__title">Doctor mappings JSON</div>' +
            '<div class="ident-widget-card__text">Редактирование алиасов и amoCRM ID после первой выгрузки расписания из IDENT.</div>' +
            '<textarea class="ident-widget-editor ident-widget-editor_tall" data-ident-mappings-json></textarea>' +
          '</div>' +
          '<div class="ident-widget-status" data-ident-advanced-status>' +
            'Backend: ' + escapeHtml(config.backendUrl || 'не указан') +
          '</div>' +
        '</div>';

      $root.html(html);
      $('[data-ident-booking-json]').val(JSON.stringify(buildDefaultBooking(), null, 2));
      $('[data-ident-db-json]').val(JSON.stringify(buildDefaultIdentDbMapping(), null, 2));
      $('[data-ident-agent-mapping-json]').val(JSON.stringify(buildDefaultIdentDbMapping(), null, 2));
      $root.off('click.identAdvanced').on('click.identAdvanced', '[data-ident-action]', function () {
        runAdvancedAction($(this).attr('data-ident-action'));
      });
      window.setTimeout(loadAdvancedOverview, 0);
    }

    function advancedCard(key, title, text, buttons) {
      return '<div class="ident-widget-card" data-ident-card="' + escapeHtml(key) + '">' +
        '<div class="ident-widget-card__title">' + escapeHtml(title) + '</div>' +
        '<div class="ident-widget-card__text">' + escapeHtml(text) + '</div>' +
        '<div class="ident-widget-actions">' + buttons.join('') + '</div>' +
      '</div>';
    }

    function button(action, title, mode) {
      var cls = mode === 'secondary' ? ' ident-widget-btn_secondary' : '';
      return '<button type="button" class="ident-widget-btn' + cls + '" data-ident-action="' +
        escapeHtml(action) + '">' + escapeHtml(title) + '</button>';
    }

    function readinessMetric(label, value, status) {
      var cls = status ? ' ident-widget-metric_' + status : '';
      return '<div class="ident-widget-metric' + cls + '"><span>' + escapeHtml(label) +
        '</span><strong>' + escapeHtml(value) + '</strong></div>';
    }

    function formatRussianCount(value, one, few, many) {
      var count = Number(value) || 0;
      var mod100 = count % 100;
      var mod10 = count % 10;
      var word = mod100 >= 11 && mod100 <= 14
        ? many
        : mod10 === 1
          ? one
          : mod10 >= 2 && mod10 <= 4
            ? few
            : many;
      return String(count) + ' ' + word;
    }

    function loadWorkspaceLeadPreview($root) {
      var leadId = getCurrentLeadId();
      if (!leadId) {
        $root.find('[data-ident-patient-source]').text('заполните вручную');
        updateWorkspaceReadiness($root);
        return;
      }

      $root.find('[data-ident-patient-source]').text('загружаю из сделки');
      safeApiRequest('/api/amocrm/leads/preview?id=' + encodeURIComponent(leadId))
        .then(function (result) {
          if (!result.ok) {
            $root.find('[data-ident-patient-source]').text('заполните вручную');
            setLeadStatus('Не удалось заполнить пациента из сделки: ' + result.error, 'warn');
            updateWorkspaceReadiness($root);
            return;
          }
          applyWorkspaceLeadPreview($root, result.data);
          setLeadStatus('Данные пациента загружены из сделки. Проверьте их перед созданием заявки.', 'ok');
        });
    }

    function applyWorkspaceLeadPreview($root, preview) {
      state.leadPreview = preview;
      resetWorkspaceSubmission();
      var ticket = preview.mappedTicket || (preview.validation && preview.validation.ticket) || preview.rawTicket || {};
      setWorkspaceFieldIfEmpty($root, 'fullName', ticket.ClientFullName || ticket.ClientName || '');
      setWorkspaceFieldIfEmpty($root, 'phone', ticket.ClientPhone || '');
      setWorkspaceFieldIfEmpty($root, 'email', ticket.ClientEmail || '');
      $root.find('[data-ident-patient-source]').text('из сделки amoCRM');
      updateWorkspaceReadiness($root);
    }

    function setWorkspaceFieldIfEmpty($root, name, value) {
      var $field = $root.find('[data-ident-booking-field="' + name + '"]');
      if ($field.length && !String($field.val() || '').trim() && value) $field.val(value);
    }

    function readWorkspaceDraft($root) {
      function field(name) {
        return String($root.find('[data-ident-booking-field="' + name + '"]').val() || '').trim();
      }
      return {
        fullName: field('fullName'),
        phone: field('phone'),
        email: field('email'),
        comment: field('comment')
      };
    }

    function workspaceBookingChecks($root) {
      var draft = readWorkspaceDraft($root);
      return {
        slot: Boolean(state.selectedSlot),
        patient: Boolean(draft.fullName),
        phone: draft.phone.replace(/\D/g, '').length >= 10
      };
    }

    function updateWorkspaceReadiness($root) {
      if (!$root || !$root.length) return;
      var checks = workspaceBookingChecks($root);
      var ready = checks.slot && checks.patient && checks.phone;
      var rows = [
        readinessRow(checks.slot, 'Время и врач'),
        readinessRow(checks.patient, 'Пациент'),
        readinessRow(checks.phone, 'Телефон')
      ].join('');

      $root.find('[data-ident-booking-readiness]').html(
        '<div class="ident-widget-workspace__readiness-head"><strong>' +
          (ready ? 'Данные заполнены' : 'Заполните обязательные поля') +
        '</strong><span>' + Object.keys(checks).filter(function (key) { return checks[key]; }).length + '/3</span></div>' +
        '<div class="ident-widget-workspace__readiness-rows">' + rows + '</div>'
      ).toggleClass('ident-widget-workspace__readiness_ready', ready);

      var submitted = Boolean(state.submittedTicketId);
      var buttonText = state.bookingSubmitting
        ? 'Создаю заявку...'
        : submitted
          ? state.submittedStatus === 'sent_to_ident' ? 'Уже передана в IDENT' : 'Заявка создана'
          : 'Создать заявку в IDENT';
      $root.find('[data-ident-action="submit_booking"]')
        .prop('disabled', !ready || state.bookingSubmitting || submitted)
        .text(buttonText);
      $root.find('[data-ident-booking-field]')
        .prop('disabled', state.bookingSubmitting);
      $root.find('[data-ident-action="select_slot"]').each(function () {
        var key = $(this).attr('data-ident-slot-key');
        $(this).prop('disabled', state.bookingSubmitting || !state.workspaceCellOptions[key]);
      });
      $root.find('[data-ident-action="set_duration"], [data-ident-duration-select]')
        .prop('disabled', state.bookingSubmitting);
      $root.find('[data-ident-show-nonworking]').prop('disabled', state.bookingSubmitting);
      $root.find('[data-ident-booking-state]')
        .text(state.bookingSubmitting ? 'отправка' : submitted ? state.submittedStatus === 'sent_to_ident' ? 'получена' : 'в очереди' : ready ? 'готово' : 'черновик')
        .toggleClass('ident-widget-workspace__draft-state_ready', ready || submitted);
    }

    function readinessRow(ok, label) {
      return '<span class="' + (ok ? 'is-ready' : '') + '"><i>' + (ok ? '✓' : '') + '</i>' + escapeHtml(label) + '</span>';
    }

    function resetWorkspaceSubmission() {
      state.preparedBooking = null;
      state.submittedTicketId = null;
      state.submittedStatus = null;
    }

    function applyWorkspaceReservation(slot, ticketId) {
      if (!state.workspaceData || !Array.isArray(state.workspaceData.Intervals) || !slot) return;
      var start = slotTimestamp(slot.StartDateTime);
      var end = start + (Number(slot.LengthInMinutes) || 15) * 60000;
      state.workspaceData.Intervals.forEach(function (interval) {
        var intervalStart = slotTimestamp(interval.StartDateTime);
        var intervalEnd = intervalStart + (Number(interval.LengthInMinutes) || 15) * 60000;
        var sameDoctor = String(interval.DoctorId) === String(slot.DoctorId);
        var sameBranch = slot.BranchId === null || slot.BranchId === undefined ||
          String(interval.BranchId) === String(slot.BranchId);
        if (sameDoctor && sameBranch && intervalStart < end && start < intervalEnd) {
          interval.IsBusy = true;
          interval.IsReserved = true;
          interval.ReservationTicketId = ticketId;
        }
      });
      var $root = $('.ident-widget-workspace').last();
      renderWorkspaceMetrics($root);
      renderWorkspaceSlots();
    }

    function buildWorkspaceBooking($root) {
      if (!$root.length) return null;
      var checks = workspaceBookingChecks($root);
      if (!(checks.slot && checks.patient && checks.phone)) {
        updateWorkspaceReadiness($root);
        setLeadStatus('Заполните время, пациента и телефон.', 'warn');
        return null;
      }

      var draft = readWorkspaceDraft($root);
      var slot = state.selectedSlot;
      var doctors = mapById(state.workspaceData.Doctors || []);
      var branches = mapById(state.workspaceData.Branches || []);
      var leadId = getCurrentLeadId();
      var branchName = nameById(branches, slot.BranchId, '');
      state.preparedBooking = {
        id: workspaceTicketId(leadId, slot),
        dateAndTime: new Date().toISOString(),
        clientFullName: draft.fullName,
        clientPhone: draft.phone,
        clientEmail: draft.email,
        planStart: slot.StartDateTime,
        planEnd: addMinutesToIdentDate(slot.StartDateTime, slot.LengthInMinutes || 15),
        durationMinutes: slot.LengthInMinutes || 15,
        doctorId: slot.DoctorId,
        doctorName: nameById(doctors, slot.DoctorId, ''),
        branchId: slot.BranchId,
        branchName: branchName,
        comment: [
          draft.comment,
          branchName ? 'Филиал: ' + branchName + (slot.BranchId ? ' (IDENT ID ' + slot.BranchId + ')' : '') : '',
          'Длительность: ' + formatWorkspaceDuration(slot.LengthInMinutes || 15),
          'Сделка amoCRM #' + (leadId || 'не определена')
        ].filter(Boolean).join('. '),
        formName: 'IDENT amoCRM widget',
        createAmoLead: false
      };
      return state.preparedBooking;
    }

    function submitWorkspaceBooking() {
      var $root = $('.ident-widget-workspace').last();
      if (!$root.length || state.bookingSubmitting || state.submittedTicketId) return;
      var booking = buildWorkspaceBooking($root);
      if (!booking) return;

      state.bookingSubmitting = true;
      updateWorkspaceReadiness($root);
      setLeadStatus('Создаю заявку и ставлю ее в очередь IDENT...', '');
      apiRequest('/api/bookings', {
        method: 'POST',
        body: JSON.stringify(booking)
      }).then(function (data) {
        state.bookingSubmitting = false;
        state.submittedStatus = data.status || (data.queued === false ? 'ignored' : 'queued');
        state.submittedTicketId = data.duplicateOf || (data.ticket && data.ticket.Id) || booking.id;
        applyWorkspaceReservation(state.selectedSlot, state.submittedTicketId);
        updateWorkspaceReadiness($root);

        if (state.submittedStatus === 'ignored') {
          setLeadStatus('Похожая заявка уже существует. Ticket ID: ' + state.submittedTicketId + '.', 'warn');
          return;
        }
        if (state.submittedStatus === 'sent_to_ident') {
          setLeadStatus('Заявка уже была получена IDENT. Ticket ID: ' + state.submittedTicketId + '.', 'ok');
          return;
        }
        setLeadStatus(
          'Заявка создана и ожидает получения IDENT. Ticket ID: ' + state.submittedTicketId + '. Это еще не подтвержденный прием.',
          'ok'
        );
      }).catch(function (error) {
        state.bookingSubmitting = false;
        updateWorkspaceReadiness($root);
        setLeadStatus('Не удалось создать заявку: ' + error.message, 'error');
      });
    }

    function workspaceTicketId(leadId, slot) {
      var start = String(slot.StartDateTime || '').replace(/\D/g, '').slice(0, 12) || String(Date.now());
      return ['amo-widget', leadId || 'manual', slot.DoctorId || 'doctor', start].join(':');
    }

    function addMinutesToIdentDate(value, minutes) {
      var timestamp = slotTimestamp(value);
      if (!Number.isFinite(timestamp)) return '';
      var result = new Date(timestamp + (Number(minutes) || 15) * 60000);
      return /(?:Z|[+-]\d{2}:\d{2})$/i.test(String(value || ''))
        ? result.toISOString()
        : workspaceDateTimeValue(result.getTime());
    }

    function previewCurrentLead() {
      var leadId = getCurrentLeadId();
      if (!leadId) {
        setLeadStatus('Не удалось определить ID сделки.', 'error');
        return;
      }

      setLeadStatus('Проверяю сделку ' + leadId + '...', '');
      apiRequest('/api/amocrm/leads/preview?id=' + encodeURIComponent(leadId))
        .then(function (data) {
          var $root = $('.ident-widget-workspace').last();
          applyWorkspaceLeadPreview($root, data);
          setLeadStatus(
            data.readyForIdent
              ? 'Данные сделки загружены. Пациент готов к созданию заявки.'
              : 'Данные сделки загружены частично. Проверьте обязательные поля.',
            data.readyForIdent ? 'ok' : 'warn'
          );
        })
        .catch(function (error) {
          setLeadStatus(error.message, 'error');
        });
    }

    function importCurrentLead() {
      var leadId = getCurrentLeadId();
      if (!leadId) {
        setLeadStatus('Не удалось определить ID сделки.', 'error');
        return;
      }

      setLeadStatus('Передаю сделку ' + leadId + ' в очередь IDENT...', '');
      apiRequest('/api/amocrm/leads/import', {
        method: 'POST',
        body: JSON.stringify({ leadId: Number(leadId) })
      })
        .then(function (data) {
          var message = data.queued
            ? 'Заявка поставлена в очередь IDENT.'
            : 'Заявка не поставлена в очередь IDENT. Проверьте статус и причину ниже.';
          setLeadStatus(message + '\nTicketId: ' + (data.ticketId || 'не создан'), data.queued ? 'ok' : 'warn');
        })
        .catch(function (error) {
          setLeadStatus(error.message, 'error');
        });
    }

    function runSettingsHealth($root) {
      var $status = $root.find('[data-ident-settings-status]');
      setStatus($status, 'Проверяю backend...', '');
      apiRequest('/health')
        .then(function (data) {
          setStatus($status, JSON.stringify(data, null, 2), data.ok ? 'ok' : 'warn');
        })
        .catch(function (error) {
          setStatus($status, error.message, 'error');
        });
    }

    function runAdvancedAction(action) {
      var pathByAction = {
        health: '/health',
        diagnostics: '/api/diagnostics',
        schema: '/api/amocrm/schema',
        settings: '/api/settings/amocrm',
        mappings: '/api/mappings',
        timetable: '/api/timetable',
        free_slots: '/api/free-slots',
        sync_timetable: '/api/amocrm/timetable/sync',
        db_status: '/api/ident-db/status',
        db_schema: '/api/ident-db/schema',
        db_mapping: '/api/ident-db/mapping',
        db_preview: '/api/ident-db/preview',
        db_sync: '/api/ident-db/sync',
        agent_status: '/api/agent/status',
        oauth: '/oauth/amocrm/url?mode=popup',
        webhooks: '/api/amocrm/webhooks/setup',
        bootstrap: '/api/amocrm/bootstrap'
      };
      var methodByAction = {
        webhooks: 'POST',
        bootstrap: 'POST',
        sync_timetable: 'POST',
        db_sync: 'POST'
      };
      var path = pathByAction[action];
      var $status = $('[data-ident-advanced-status]');

      if (action === 'save_settings') {
        saveAdvancedJson('[data-ident-settings-json]', '/api/settings/amocrm');
        return;
      }
      if (action === 'save_mappings') {
        saveAdvancedJson('[data-ident-mappings-json]', '/api/mappings');
        return;
      }
      if (action === 'save_db_mapping') {
        saveAdvancedJson('[data-ident-db-json]', '/api/ident-db/mapping');
        return;
      }
      if (action === 'create_booking') {
        createTestBooking();
        return;
      }
      if (action === 'save_agent') {
        saveAgentSettings();
        return;
      }
      if (action === 'agent_schema') {
        loadAgentSchema();
        return;
      }
      if (action === 'save_agent_mapping') {
        saveAgentMapping();
        return;
      }

      if (!path) return;

      var oauthWindow = action === 'oauth' ? openBlankWindow() : null;
      setStatus($status, 'Выполняю ' + action + '...', '');
      apiRequest(path, { method: methodByAction[action] || 'GET' })
        .then(function (data) {
          if (action === 'oauth') {
            openOAuthUrl(data, oauthWindow);
            setStatus($status, 'Открыл окно авторизации amoCRM.\n' + (data.url || JSON.stringify(data, null, 2)), data.url ? 'ok' : 'warn');
            return;
          }
          if (action === 'settings') $('[data-ident-settings-json]').val(JSON.stringify(data.settings || data, null, 2));
          if (action === 'mappings') $('[data-ident-mappings-json]').val(JSON.stringify(data, null, 2));
          if (action === 'db_mapping') {
            $('[data-ident-db-json]').val(JSON.stringify(data, null, 2));
            setStatus($status, 'SQL-маппинг загружен.', 'ok');
            return;
          }
          if (action === 'db_status') {
            renderIdentDbStatus(data);
            setStatus($status, JSON.stringify(data, null, 2), data.ok ? 'ok' : 'warn');
            return;
          }
          if (action === 'db_schema') {
            renderIdentDbSchema(data);
            $('[data-ident-db-json]').val(JSON.stringify(data, null, 2));
            setStatus($status, formatIdentDbSchemaStatus(data), 'ok');
            return;
          }
          if (action === 'db_preview' || action === 'db_sync') {
            var timetable = data.timetable || data;
            $('[data-ident-schedule-json]').val(JSON.stringify(timetable, null, 2));
            renderScheduleSummary(timetable, false);
            renderIdentDbPreview(data, action === 'db_sync');
            setStatus($status, formatScheduleStatus(timetable, false), 'ok');
            return;
          }
          if (action === 'agent_status') {
            renderAgentStatus(data);
            setStatus($status, 'Состояние агента обновлено.', data.agents && data.agents.length ? 'ok' : 'warn');
            return;
          }
          if (action === 'timetable' || action === 'free_slots') {
            $('[data-ident-schedule-json]').val(JSON.stringify(data, null, 2));
            renderScheduleSummary(data, action === 'free_slots');
            if (action === 'free_slots') prefillBookingFromSchedule(data);
            setStatus($status, formatScheduleStatus(data, action === 'free_slots'), 'ok');
            return;
          }
          setStatus($status, JSON.stringify(data, null, 2), data.status === 'error' ? 'error' : 'ok');
        })
        .catch(function (error) {
          if (oauthWindow && !oauthWindow.closed) oauthWindow.close();
          setStatus($status, error.message, 'error');
        });
    }

    function loadAdvancedOverview() {
      Promise.all([
        safeApiRequest('/health'),
        safeApiRequest('/api/diagnostics'),
        safeApiRequest('/api/agent/status'),
        safeApiRequest('/api/timetable')
      ]).then(function (results) {
        var health = results[0];
        var diagnostics = results[1];
        var agents = results[2];
        var timetable = results[3];

        renderReadiness(health, diagnostics, agents, timetable);
        if (agents.ok) renderAgentStatus(agents.data);
        if (timetable.ok) {
          $('[data-ident-schedule-json]').val(JSON.stringify(timetable.data, null, 2));
          renderScheduleSummary(timetable.data, false);
        }
      });
    }

    function safeApiRequest(path) {
      return apiRequest(path)
        .then(function (data) {
          return { ok: true, data: data };
        })
        .catch(function (error) {
          return { ok: false, error: error.message };
        });
    }

    function renderReadiness(healthResult, diagnosticsResult, agentsResult, timetableResult) {
      var health = healthResult.ok ? healthResult.data : {};
      var diagnostics = diagnosticsResult.ok ? diagnosticsResult.data : {};
      var agentList = agentsResult.ok && agentsResult.data.agents ? agentsResult.data.agents : [];
      var agentOnline = agentList.some(function (agent) { return agent.online; });
      var onlineAgent = agentList.find(function (agent) { return agent.online; }) || null;
      var timetable = timetableResult.ok ? timetableResult.data : null;
      var timetableSummary = timetable && timetable.Summary ? timetable.Summary : null;
      var notes = [];

      state.amoReady = Boolean(health.amoConfigured);
      $('[data-ident-action="create_booking"]').prop('disabled', !state.amoReady);

      if (!healthResult.ok || !health.ok) notes.push('Сервис недоступен.');
      if (!state.amoReady) {
        if (diagnostics.amoCRM && diagnostics.amoCRM.oauthConfigured === false) {
          var missing = diagnostics.amoCRM.oauthMissing || [];
          notes.push(
            'OAuth не настроен на сервере' +
            (missing.length ? ': ' + missing.join(', ') + '.' : '.')
          );
        } else {
          notes.push('Нужно авторизовать amoCRM.');
        }
      }
      if (!agentOnline) notes.push('Агент клиники еще не на связи.');
      if (onlineAgent && onlineAgent.schedule && onlineAgent.schedule.state === 'needs_mapping') {
        notes.push('Нужно настроить таблицы расписания.');
      }
      if (!timetable) notes.push('Расписание еще не получено.');
      if (diagnostics.status === 'error') notes.push('Диагностика обнаружила критическую ошибку.');

      $('[data-ident-readiness-metrics]').html(
        readinessMetric('Сервис', healthResult.ok && health.ok ? 'работает' : 'ошибка', healthResult.ok && health.ok ? 'ok' : 'error') +
        readinessMetric('amoCRM', state.amoReady ? 'подключена' : 'не подключена', state.amoReady ? 'ok' : 'warn') +
        readinessMetric('Агент', agentOnline ? 'на связи' : 'нет связи', agentOnline ? 'ok' : 'warn') +
        readinessMetric(
          'Расписание',
          timetableSummary ? formatRussianCount(timetableSummary.intervals, 'окно', 'окна', 'окон') : 'нет данных',
          timetable ? 'ok' : 'warn'
        )
      );

      $('[data-ident-readiness-note]')
        .removeClass('ident-widget-readiness-note_ok ident-widget-readiness-note_warn ident-widget-readiness-note_error')
        .addClass(
          diagnostics.status === 'error'
            ? 'ident-widget-readiness-note_error'
            : notes.length
              ? 'ident-widget-readiness-note_warn'
              : 'ident-widget-readiness-note_ok'
        )
        .text(notes.length ? notes.join(' ') : 'Все основные компоненты готовы к работе.');
    }

    function loadAgentStatus() {
      apiRequest('/api/agent/status')
        .then(function (data) {
          renderAgentStatus(data);
        })
        .catch(function (error) {
          $('[data-ident-agent-summary]').html(
            '<div class="ident-widget-empty">' + escapeHtml(error.message) + '</div>'
          );
        });
    }

    function renderAgentStatus(data) {
      var agents = data.agents || [];
      var $summary = $('[data-ident-agent-summary]');
      if (!agents.length) {
        $summary.html('<div class="ident-widget-empty">Агент еще не выходил на связь.</div>');
        $('[data-ident-agent-schedule]').prop('checked', false);
        $('[data-ident-agent-robot]').prop('checked', false);
        return;
      }

      var agent = agents[0];
      var desired = (data.desired && data.desired[agent.agentId]) || {
        scheduleEnabled: agent.schedule && agent.schedule.enabled,
        robotEnabled: agent.robot && agent.robot.enabled
      };
      var schedule = agent.schedule || {};
      var robot = agent.robot || {};
      var statusText = agent.online ? 'на связи' : 'не отвечает';
      var statusClass = agent.online ? 'ident-widget-agent-online' : 'ident-widget-agent-offline';

      $summary.attr('data-agent-id', agent.agentId).html(
        '<div class="ident-widget-metrics">' +
          metric('Агент', statusText) +
          metric('Компьютер', agent.deviceName || agent.agentId) +
          metric('Расписание', formatAgentState(schedule.state)) +
          metric('Робот', formatAgentState(robot.state)) +
        '</div>' +
        '<div class="ident-widget-agent-line ' + statusClass + '">' +
          escapeHtml(agent.agentId + ' · последний сигнал ' + formatDateTime(agent.lastSeenAt)) +
        '</div>' +
        '<div class="ident-widget-card__text">' +
          'Последняя выгрузка: ' + escapeHtml(formatDateTime(schedule.lastSuccessAt) || 'нет') +
          '. Врачи: ' + escapeHtml(schedule.doctors || 0) +
          ', филиалы: ' + escapeHtml(schedule.branches || 0) +
          ', окна: ' + escapeHtml(schedule.intervals || 0) +
          ', свободно: ' + escapeHtml(schedule.freeIntervals || 0) +
          ', услуги: ' + escapeHtml(schedule.services || 0) + '.' +
        '</div>' +
        (schedule.lastError ? '<div class="ident-widget-agent-error">' + escapeHtml(schedule.lastError) + '</div>' : '') +
        (robot.lastError ? '<div class="ident-widget-agent-error">' + escapeHtml(robot.lastError) + '</div>' : '')
      );
      $('[data-ident-agent-schedule]').prop('checked', Boolean(desired.scheduleEnabled));
      $('[data-ident-agent-robot]').prop('checked', Boolean(desired.robotEnabled));
      if (desired.scheduleMapping) {
        $('[data-ident-agent-mapping-json]').val(JSON.stringify(desired.scheduleMapping, null, 2));
      }
    }

    function loadAgentSchema() {
      var $summary = $('[data-ident-agent-summary]');
      var agentId = $summary.attr('data-agent-id');
      var $status = $('[data-ident-advanced-status]');
      if (!agentId) {
        setStatus($status, 'Агент еще не зарегистрирован на сервере.', 'warn');
        return;
      }

      setStatus($status, 'Загружаю структуру базы агента...', '');
      apiRequest('/api/agent/schema?agentId=' + encodeURIComponent(agentId))
        .then(function (data) {
          $('[data-ident-agent-schema-json]').val(JSON.stringify(data, null, 2));
          renderAgentSchemaSummary(data);
          setStatus($status, 'Структура базы загружена. Можно подготовить SQL-маппинг.', 'ok');
        })
        .catch(function (error) {
          setStatus($status, error.message, 'error');
        });
    }

    function renderAgentSchemaSummary(data) {
      var summary = data.summary || {};
      $('[data-ident-agent-schema-summary]').html(
        '<div class="ident-widget-metrics">' +
          metric('База', data.database || 'не определена') +
          metric('Таблицы', summary.tables || 0) +
          metric('Колонки', summary.columns || 0) +
          metric('Получено', formatDateTime(data.receivedAt) || 'нет') +
        '</div>'
      );
    }

    function saveAgentMapping() {
      var $summary = $('[data-ident-agent-summary]');
      var agentId = $summary.attr('data-agent-id');
      var $status = $('[data-ident-advanced-status]');
      if (!agentId) {
        setStatus($status, 'Агент еще не зарегистрирован на сервере.', 'warn');
        return;
      }
      var mapping = parseJson($('[data-ident-agent-mapping-json]').val());
      if (!mapping) {
        setStatus($status, 'SQL-маппинг не распознан. Проверьте JSON.', 'error');
        return;
      }
      if (!window.confirm('Передать проверенные read-only SQL-запросы агенту клиники?')) return;

      setStatus($status, 'Передаю SQL-маппинг агенту...', '');
      apiRequest('/api/agent/settings', {
        method: 'POST',
        body: JSON.stringify({
          agentId: agentId,
          scheduleEnabled: true,
          scheduleMapping: mapping
        })
      })
        .then(function (data) {
          var revision = data.desired && data.desired.mappingRevision
            ? formatDateTime(data.desired.mappingRevision)
            : 'создана';
          setStatus($status, 'Маппинг сохранен. Ревизия: ' + revision + '. Агент применит его при следующем сигнале.', 'ok');
          loadAgentStatus();
        })
        .catch(function (error) {
          setStatus($status, error.message, 'error');
        });
    }

    function saveAgentSettings() {
      var $summary = $('[data-ident-agent-summary]');
      var agentId = $summary.attr('data-agent-id');
      var $status = $('[data-ident-advanced-status]');
      if (!agentId) {
        setStatus($status, 'Агент еще не зарегистрирован на сервере.', 'warn');
        return;
      }

      var robotEnabled = $('[data-ident-agent-robot]').is(':checked');
      if (robotEnabled && !window.confirm('Включить робота? Без откалиброванных элементов IDENT он останется в состоянии "нужна настройка" и не заберет заявки.')) {
        $('[data-ident-agent-robot]').prop('checked', false);
        robotEnabled = false;
      }

      setStatus($status, 'Сохраняю состояние агента...', '');
      apiRequest('/api/agent/settings', {
        method: 'POST',
        body: JSON.stringify({
          agentId: agentId,
          scheduleEnabled: $('[data-ident-agent-schedule]').is(':checked'),
          robotEnabled: robotEnabled
        })
      })
        .then(function () {
          setStatus($status, 'Переключатели сохранены. Агент применит их при следующем сигнале.', 'ok');
          loadAgentStatus();
        })
        .catch(function (error) {
          setStatus($status, error.message, 'error');
        });
    }

    function formatAgentState(value) {
      var names = {
        starting: 'запуск',
        sending: 'отправка',
        ok: 'работает',
        error: 'ошибка',
        disabled: 'выключено',
        checking: 'проверка',
        processing: 'выполнение',
        idle: 'ожидание',
        needs_configuration: 'нужна настройка',
        needs_mapping: 'нужно сопоставить таблицы',
        mapping_error: 'ошибка маппинга'
      };
      return names[value] || value || 'нет данных';
    }

    function openBlankWindow() {
      try {
        return window.open('about:blank', 'ident_amo_oauth');
      } catch (error) {
        return null;
      }
    }

    function openOAuthUrl(data, popup) {
      if (!data || !data.url) return;
      try {
        if (popup) {
          popup.location.href = data.url;
          if (typeof popup.focus === 'function') popup.focus();
          return;
        }
        window.open(data.url, 'ident_amo_oauth');
      } catch (error) {
        // The URL is also rendered into the status block for manual copy when popups are blocked.
      }
    }

    function saveAdvancedJson(selector, path) {
      var $status = $('[data-ident-advanced-status]');
      var raw = $(selector).val();
      var payload = parseJson(raw);
      if (!payload) {
        setStatus($status, 'JSON не распознан. Проверьте синтаксис.', 'error');
        return;
      }
      setStatus($status, 'Сохраняю...', '');
      apiRequest(path, {
        method: 'POST',
        body: JSON.stringify(payload)
      })
        .then(function (data) {
          setStatus($status, JSON.stringify(data, null, 2), 'ok');
        })
        .catch(function (error) {
          setStatus($status, error.message, 'error');
        });
    }

    function createTestBooking() {
      var $status = $('[data-ident-advanced-status]');
      if (!state.amoReady) {
        setStatus($status, 'Сначала авторизуйте amoCRM. Тестовая заявка не была создана и не попала в очередь IDENT.', 'warn');
        return;
      }
      var payload = parseJson($('[data-ident-booking-json]').val());
      if (!payload) {
        setStatus($status, 'JSON тестовой записи не распознан. Проверьте синтаксис.', 'error');
        return;
      }
      if (!window.confirm('Создать тестовую сделку в amoCRM и поставить ее в очередь IDENT?')) return;
      payload.requireAmoLead = true;

      setStatus($status, 'Создаю тестовую запись и сделку amoCRM...', '');
      apiRequest('/api/bookings', {
        method: 'POST',
        body: JSON.stringify(payload)
      })
        .then(function (data) {
          setStatus(
            $status,
            'Тестовая запись создана.\nTicketId: ' + (data.ticket && data.ticket.Id ? data.ticket.Id : 'не создан') +
              '\namoLeadId: ' + (data.amoLeadId || 'не создан'),
            data.amoLeadId ? 'ok' : 'warn'
          );
        })
        .catch(function (error) {
          setStatus($status, error.message, 'error');
        });
    }

    function renderScheduleSummary(data, freeOnly) {
      var doctors = data.Doctors || [];
      var branches = data.Branches || [];
      var intervals = data.Intervals || [];
      var services = data.Services || [];
      var freeCount = freeOnly ? intervals.length : intervals.filter(function (item) { return !item.IsBusy; }).length;
      var busyCount = freeOnly ? 0 : intervals.length - freeCount;
      var doctorMap = mapById(doctors);
      var branchMap = mapById(branches);
      var rows = intervals.slice(0, 12).map(function (item) {
        return '<tr>' +
          '<td>' + escapeHtml(formatDateTime(item.StartDateTime)) + '</td>' +
          '<td>' + escapeHtml(nameById(doctorMap, item.DoctorId, 'Doctor ' + item.DoctorId)) + '</td>' +
          '<td>' + escapeHtml(nameById(branchMap, item.BranchId, 'Branch ' + item.BranchId)) + '</td>' +
          '<td>' + escapeHtml(item.IsBusy ? 'занято' : 'свободно') + '</td>' +
        '</tr>';
      }).join('');

      $('[data-ident-schedule-summary]').html(
        '<div class="ident-widget-metrics">' +
          metric('Врачи', doctors.length) +
          metric('Филиалы', branches.length) +
          metric('Окна', intervals.length) +
          metric('Свободно', freeCount) +
          metric('Занято', busyCount) +
          metric('Услуги', services.length) +
        '</div>' +
        '<div class="ident-widget-card__text">Получено: ' + escapeHtml(data.receivedAt || 'нет данных') + '</div>' +
        '<table class="ident-widget-table">' +
          '<thead><tr><th>Время</th><th>Врач</th><th>Филиал</th><th>Статус</th></tr></thead>' +
          '<tbody>' + (rows || '<tr><td colspan="4">Нет интервалов для отображения.</td></tr>') + '</tbody>' +
        '</table>'
      );
    }

    function prefillBookingFromSchedule(data) {
      var intervals = data.Intervals || [];
      var slot = intervals.find(function (item) { return !item.IsBusy; }) || intervals[0];
      if (!slot) return;
      var doctor = nameById(mapById(data.Doctors || []), slot.DoctorId, '');
      $('[data-ident-booking-json]').val(JSON.stringify({
        id: 'widget-test-' + Date.now(),
        dateAndTime: new Date().toISOString(),
        clientFullName: 'Тестовая запись amoCRM IDENT',
        clientPhone: '+79110001122',
        clientEmail: 'test@example.ru',
        planStart: slot.StartDateTime,
        doctorId: slot.DoctorId,
        doctorName: doctor,
        comment: 'Тестовая запись из виджета IDENT amoCRM',
        formName: 'IDENT amoCRM widget'
      }, null, 2));
    }

    function buildDefaultBooking() {
      return {
        id: 'widget-test-' + Date.now(),
        dateAndTime: new Date().toISOString(),
        clientFullName: 'Тестовая запись amoCRM IDENT',
        clientPhone: '+79110001122',
        clientEmail: 'test@example.ru',
        planStart: '',
        doctorId: '',
        doctorName: '',
        comment: 'Тестовая запись из виджета IDENT amoCRM',
        formName: 'IDENT amoCRM widget'
      };
    }

    function buildDefaultIdentDbMapping() {
      return {
        doctorsSql: 'SELECT Id, Name FROM dbo.Doctors',
        branchesSql: 'SELECT Id, Name FROM dbo.Branches',
        intervalsSql: 'SELECT DoctorId, BranchId, StartDateTime, LengthInMinutes, IsBusy FROM dbo.Schedule',
        servicesSql: [
          'SELECT si.ID AS Id, si.Name AS Name, sic.Code AS Code, sip.Price AS Price,',
          '  sip.ID AS PriceId, spg.ID AS PriceGroupId, spg.Name AS PriceGroupName,',
          '  sf.ID AS FolderId, sf.Name AS FolderName, sc.ID AS CategoryId, sc.Name AS CategoryName',
          'FROM dbo.ServiceItems si',
          'JOIN dbo.ServiceItemPrices sip ON sip.ID_ServiceItems = si.ID',
          'JOIN dbo.ServicePriceGroups spg ON spg.ID = sip.ID_ServicePriceGroups',
          'LEFT JOIN dbo.ServiceItemContents sic ON sic.ID_ServiceItems = si.ID',
          '  AND sic.DateTimeFrom <= GETDATE() AND (sic.DateTimeTo IS NULL OR sic.DateTimeTo > GETDATE())',
          'LEFT JOIN dbo.ServiceFolders sf ON sf.ID = sic.ID_ServiceFoldersParent AND sf.Archive = 0',
          'LEFT JOIN dbo.ServiceCategories sc ON sc.ID = sf.ID_ServiceCategories AND sc.Archive = 0',
          'WHERE si.NotAService = 0 AND spg.Archive = 0',
          '  AND sip.DateTimeFrom <= GETDATE() AND (sip.DateTimeTo IS NULL OR sip.DateTimeTo > GETDATE())',
          'ORDER BY sf.Name, si.Name, spg.Name'
        ].join('\n'),
        notes: [
          'Первые три запроса заменяются по реальной схеме расписания IDENT.',
          'Запрос услуг подготовлен по таблицам ServiceItems и ServiceItemPrices базы клиента.',
          'Все запросы должны быть только SELECT/WITH без записи в БД.'
        ]
      };
    }

    function renderIdentDbStatus(data) {
      $('[data-ident-db-summary]').html(
        '<div class="ident-widget-metrics">' +
          metric('Статус', data.status || 'unknown') +
          metric('Готово', data.ready ? 'да' : 'нет') +
          metric('Сервер', data.connection && data.connection.server ? data.connection.server : 'не задан') +
          metric('База', data.connection && data.connection.database ? data.connection.database : 'не задана') +
        '</div>' +
        '<div class="ident-widget-card__text">' + escapeHtml(data.error || 'Read-only подключение проверено.') + '</div>'
      );
    }

    function renderIdentDbSchema(data) {
      var tables = (data.tables || []).slice(0, 20);
      var rows = tables.map(function (table) {
        var columns = (table.columns || []).slice(0, 8).map(function (column) {
          return column.name + ':' + column.type;
        }).join(', ');
        return '<tr>' +
          '<td>' + escapeHtml(table.schema + '.' + table.name) + '</td>' +
          '<td>' + escapeHtml(table.type || '') + '</td>' +
          '<td>' + escapeHtml(columns) + '</td>' +
        '</tr>';
      }).join('');

      $('[data-ident-db-summary]').html(
        '<div class="ident-widget-metrics">' +
          metric('Таблиц', data.summary ? data.summary.tables : tables.length) +
          metric('Колонок', data.summary ? data.summary.columns : 0) +
          metric('Показано', tables.length) +
        '</div>' +
        '<table class="ident-widget-table">' +
          '<thead><tr><th>Таблица</th><th>Тип</th><th>Первые колонки</th></tr></thead>' +
          '<tbody>' + (rows || '<tr><td colspan="3">Схема не получена.</td></tr>') + '</tbody>' +
        '</table>'
      );
    }

    function renderIdentDbPreview(data, synced) {
      var timetable = data.timetable || {};
      $('[data-ident-db-summary]').html(
        '<div class="ident-widget-metrics">' +
          metric('Источник', data.source || 'ident-db') +
          metric('Sync', synced ? 'выполнен' : 'preview') +
          metric('Врачей', (timetable.Doctors || []).length) +
          metric('Окон', (timetable.Intervals || []).length) +
        '</div>' +
        '<div class="ident-widget-card__text">' +
          escapeHtml(synced ? 'Данные из БД сохранены как текущее расписание для amoCRM.' : 'Preview построен без сохранения расписания.') +
        '</div>'
      );
    }

    function formatIdentDbSchemaStatus(data) {
      return 'Схема IDENT DB загружена.\nТаблиц: ' + (data.summary ? data.summary.tables : 0) +
        '\nКолонок: ' + (data.summary ? data.summary.columns : 0);
    }

    function formatScheduleStatus(data, freeOnly) {
      var intervals = data.Intervals || [];
      var freeCount = freeOnly ? intervals.length : intervals.filter(function (item) { return !item.IsBusy; }).length;
      return 'Расписание загружено.\nВрачей: ' + (data.Doctors || []).length +
        '\nФилиалов: ' + (data.Branches || []).length +
        '\nОкон: ' + intervals.length +
        '\nСвободно: ' + freeCount +
        '\nУслуг: ' + (data.Services || []).length;
    }

    function metric(label, value) {
      return '<div class="ident-widget-metric"><span>' + escapeHtml(label) + '</span><strong>' + escapeHtml(value) + '</strong></div>';
    }

    function mapById(items) {
      var map = {};
      (items || []).forEach(function (item) {
        map[item.Id] = item;
      });
      return map;
    }

    function nameById(map, id, fallback) {
      return map[id] && map[id].Name ? map[id].Name : fallback;
    }

    function formatDateTime(value) {
      if (!value) return '';
      return String(value).replace('T', ' ').replace(/([+-]\d\d:\d\d|Z)$/, '');
    }

    function apiRequest(path, options) {
      var config = getConfig();
      var requestOptions = options || {};
      if (!config.backendUrl) {
        return Promise.reject(new Error('В настройках не указан URL backend.'));
      }
      if (!isAllowedBackendUrl(config.backendUrl)) {
        return Promise.reject(new Error('Backend URL должен начинаться с https://. Для локальной проверки допустимы localhost и 127.0.0.1.'));
      }

      var headers = {
        Accept: 'application/json'
      };
      if (config.serviceApiKey) headers['X-API-Key'] = config.serviceApiKey;
      if (requestOptions.body) headers['Content-Type'] = 'application/json';

      return fetch(config.backendUrl + path, {
        method: requestOptions.method || 'GET',
        headers: headers,
        body: requestOptions.body || undefined,
        credentials: 'omit'
      }).then(function (response) {
        return response.text().then(function (text) {
          var body = parseJson(text);
          if (!response.ok) {
            throw new Error((body && (body.error || body.message)) || text || ('HTTP ' + response.status));
          }
          return body || { ok: true };
        });
      });
    }

    function formatPreview(data) {
      var validation = data.validation || {};
      var ticket = validation.ticket || {};
      var lines = [
        'Готово к IDENT: ' + (data.readyForIdent ? 'да' : 'нет'),
        'Валидация: ' + (validation.ok ? 'ок' : 'есть замечания'),
        'TicketId=' + (ticket.Id || ''),
        'Клиент: ' + (ticket.ClientFullName || ''),
        'Телефон: ' + (ticket.ClientPhone || ''),
        'Запись: ' + (ticket.PlanStart || ''),
        'DoctorId: ' + (ticket.DoctorId || ''),
        'Врач: ' + (ticket.DoctorName || '')
      ];
      if (validation.errors && validation.errors.length) {
        lines.push('Ошибки: ' + validation.errors.join('; '));
      }
      if (data.mapping && data.mapping.reason) {
        lines.push('Mapping: ' + data.mapping.reason);
      }
      return lines.join('\n');
    }

    function setLeadStatus(message, status) {
      setStatus($('.ident-widget-workspace [data-ident-status]').last(), message, status);
    }

    function setStatus($node, message, status) {
      if (!$node || !$node.length) return;
      $node
        .removeClass('ident-widget-status_ok ident-widget-status_warn ident-widget-status_error')
        .addClass(status ? 'ident-widget-status_' + status : '')
        .text(message || '');
    }

    function getCurrentLeadId() {
      var fromAmo = readAmoCardId();
      if (fromAmo) return fromAmo;

      var match = String(window.location.pathname || '').match(/\/leads\/detail\/(\d+)/);
      if (match) return match[1];

      var $id = $('[name="lead[id]"],[name="ID"],[data-id]').filter(function () {
        return /^\d+$/.test(String($(this).val() || $(this).attr('data-id') || ''));
      }).first();
      return $id.val() || $id.attr('data-id') || '';
    }

    function readAmoCardId() {
      try {
        if (window.APP && typeof window.APP.constant === 'function') {
          return window.APP.constant('card_id') || '';
        }
      } catch (error) {
        return '';
      }
      return '';
    }

    function isLeadCard() {
      return /\/leads\/detail\/\d+/.test(String(window.location.pathname || '')) || Boolean(readAmoCardId());
    }

    function findLeadHost() {
      var selectors = [
        '.card-holder__fields',
        '.card-fields',
        '.linked-form',
        '#card_holder',
        '.card-holder'
      ];
      for (var index = 0; index < selectors.length; index += 1) {
        var $node = $(selectors[index]).first();
        if ($node.length) return $node;
      }
      return $('body');
    }

    function parseJson(text) {
      if (!text) return null;
      try {
        return JSON.parse(text);
      } catch (error) {
        return null;
      }
    }

    function trimSlash(value) {
      return $.trim(String(value || '')).replace(/\/+$/, '');
    }

    function isAllowedBackendUrl(value) {
      if (/^https:\/\//i.test(value)) return true;
      return /^http:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/i.test(value);
    }

    function escapeHtml(value) {
      return String(value === undefined || value === null ? '' : value).replace(/[&<>"']/g, function (char) {
        return {
          '&': '&amp;',
          '<': '&lt;',
          '>': '&gt;',
          '"': '&quot;',
          "'": '&#39;'
        }[char];
      });
    }

    return this;
  };
});
