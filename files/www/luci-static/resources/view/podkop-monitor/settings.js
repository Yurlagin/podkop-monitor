'use strict';
'require view';
'require form';
'require uci';
'require fs';
'require ui';

return view.extend({
	load() {
		return uci.load('podkop');
	},

	render() {
		const m = new form.Map('podkop-monitor', 'Podkop Monitor — настройки',
			'Мониторинг проверяет серверы из секций podkop и, если задана подписка, все серверы VPN-провайдера.');
		const s = m.section(form.NamedSection, 'main', 'main');
		s.addremove = false;
		s.tab('main', 'Основное');
		s.tab('advanced', 'Дополнительно');

		let o = s.taboption('main', form.Flag, 'enabled', 'Включить');
		o.default = '1';
		o.rmempty = false;

		o = s.taboption('main', form.Value, 'subscription_url', 'Ссылка на подписку',
			'Та же ссылка, что вы добавляете в Happ / v2rayN / Hiddify. Поддерживаются Xray-JSON и обычный список ссылок. ' +
			'Пусто — проверяются только серверы из секций podkop. После сохранения список серверов обновится сам.');
		o.placeholder = 'https://…';
		o.validate = (id, v) => !v || /^https?:\/\/\S+$/.test(v) || 'Нужна ссылка http(s)://';

		o = s.taboption('main', form.ListValue, 'interval', 'Период проверки');
		[['5', '5 минут'], ['10', '10 минут'], ['15', '15 минут'], ['30', '30 минут']].forEach(([k, v]) => o.value(k, v));
		o.default = '15';

		o = s.taboption('main', form.ListValue, 'keep_days', 'Хранить историю');
		[['1', '1 день'], ['3', '3 дня'], ['7', '7 дней'], ['14', '14 дней']].forEach(([k, v]) => o.value(k, v));
		o.default = '7';

		o = s.taboption('main', form.Flag, 'youtube_country', 'Проверять страну YouTube',
			'Раз в сутки узнаёт, какую страну видит YouTube через каждый сервер подписки (от неё зависит реклама). ' +
			'Использует недокументированный ответ YouTube и может перестать работать.');
		o.default = '1';
		o.rmempty = false;

		o = s.taboption('main', form.ListValue, 'auto_update', 'Автообновление ссылок',
			'Заменять ссылки в секциях podkop ссылками из подписки без подтверждения. ' +
			'«Только неработающие» — если ссылка отличается от подписки, через podkop сервер не отвечает две проверки подряд, ' +
			'а по ссылке из подписки отвечает. «Все изменённые» — при любом расхождении: затрёт и намеренные правки ' +
			'(например, свой SNI) — такие серверы добавьте в исключения. Перед каждой заменой сохраняется копия конфига podkop.');
		o.value('off', 'Выключено');
		o.value('outdated', 'Только неработающие');
		o.value('all', 'Все изменённые');
		o.default = 'off';

		o = s.taboption('main', form.DynamicList, 'auto_update_exclude', 'Не обновлять автоматически',
			'Имена серверов как в podkop, например 🇷🇺Moscow.');
		o.depends('auto_update', 'outdated');
		o.depends('auto_update', 'all');
		uci.sections('podkop', 'section').forEach(sec => {
			L.toArray(sec.urltest_proxy_links).concat(L.toArray(sec.selector_proxy_links)).forEach(link => {
				let name = '';
				try { name = decodeURIComponent((link.split('#')[1] || '').replace(/\+/g, ' ')); } catch (e) {}
				if (name && !this.names?.has(name)) { (this.names ??= new Set()).add(name); o.value(name, name); }
			});
		});

		o = s.taboption('main', form.Flag, 'update_check', 'Проверять обновления', 'Раз в сутки сверяется с релизами на GitHub.');
		o.default = '1';
		o.rmempty = false;

		o = s.taboption('main', form.Flag, 'auto_upgrade', 'Обновлять автоматически',
			'Сразу ставить новую версию мониторинга, как только она выйдет (раз в сутки, ночью). ' +
			'Настройки и история сохраняются. Выключите, если хотите обновлять вручную кнопкой на странице мониторинга.');
		o.default = '1';
		o.rmempty = false;
		o.depends('update_check', '1');

		o = s.taboption('advanced', form.Value, 'subscription_ua', 'User-Agent для подписки',
			'От него зависит формат ответа сервера подписки.');
		o.default = 'v2rayNG/1.9.30';

		o = s.taboption('advanced', form.Value, 'repo', 'Репозиторий GitHub', 'Откуда брать обновления: владелец/репозиторий.');

		o = s.taboption('advanced', form.Value, 'parallel', 'Серверов одновременно',
			'Сколько серверов подписки проверять параллельно. Если ставить много, часть проверок ложно падает.');
		o.datatype = 'range(1,32)';
		o.default = '8';

		o = s.taboption('advanced', form.Value, 'timeout', 'Таймаут проверки, мс');
		o.datatype = 'range(1000,15000)';
		o.default = '5000';

		o = s.taboption('advanced', form.Value, 'helper_port', 'Порт API вспомогательного sing-box', 'Слушает только 127.0.0.1.');
		o.datatype = 'port';
		o.default = '9092';

		o = s.taboption('advanced', form.Value, 'base_port', 'Начальный порт входов на серверы',
			'Сервер N подписки доступен на 127.0.0.1:(порт+N) — для проверки страны YouTube.');
		o.datatype = 'port';
		o.default = '32000';

		// --- уведомления в Telegram ---
		const n = m.section(form.NamedSection, 'notify', 'notify', 'Уведомления в Telegram',
			'Сообщение придёт, когда что-то требует вашего вмешательства: подписка резко изменилась, сервер из секции пропал из подписки ' +
			'или перестал работать и сам не починился, переименование нужно выбрать вручную, подписка не скачивается, трафик на исходе. ' +
			'Одно сообщение на событие; о нерешённом — напоминание раз в сутки; когда проблема ушла — «решено».');
		n.addremove = false;
		const val = (name, sid) => m.lookupOption(name, sid)[0].formvalue(sid);
		const CLI = '/usr/bin/podkop-monitor';
		const out = res => (res.stdout || res.stderr || '').trim();

		o = n.option(form.Flag, 'enabled', 'Включить');
		o.default = '0';
		o.rmempty = false;

		o = n.option(form.Value, 'bot_token', 'Токен бота',
			'Создайте бота: напишите @BotFather в Telegram команду /newbot и скопируйте выданный токен. ' +
			'Затем напишите своему боту любое сообщение — без этого он не сможет писать вам.');
		o.password = true;
		o.placeholder = '123456789:AA…';
		o.validate = (id, v) => !v || /^\d+:[\w-]{20,}$/.test(v) || 'Похоже, это не токен бота';

		o = n.option(form.Value, 'chat_id', 'ID чата', 'Нажмите «Определить» после того, как написали боту.');
		o.datatype = 'string';
		o.placeholder = '123456789';

		o = n.option(form.Button, '_chatid', ' ');
		o.inputtitle = 'Определить ID чата';
		o.inputstyle = 'action';
		o.onclick = (ev, sid) => {
			const token = val('bot_token', sid);
			if (!token) return ui.addNotification(null, E('p', 'Сначала впишите токен бота'), 'warning');
			return fs.exec(CLI, ['notify-chatid', token, val('via_proxy', sid) === '1' ? '1' : '0']).then(res => {
				if (res.code !== 0) return ui.addNotification(null, E('p', out(res)), 'error');
				m.lookupOption('chat_id', sid)[0].getUIElement(sid).setValue(out(res));
				ui.addNotification(null, E('p', `ID чата: ${out(res)}. Нажмите «Сохранить и применить».`), 'info');
			});
		};

		o = n.option(form.Flag, 'via_proxy', 'Через прокси podkop',
			'Отправлять через локальный прокси podkop: Telegram API в России может блокироваться. Нужен включённый «Mixed proxy» в основной секции podkop.');
		o.default = '1';
		o.rmempty = false;

		o = n.option(form.Flag, 'ev_attention', 'Серверы и подписка требуют вмешательства',
			'Подписка резко изменилась; сервер из секции пропал из подписки; не отвечает и сам не обновился; переименование нужно выбрать вручную.');
		o.default = '1';
		o.rmempty = false;

		o = n.option(form.Flag, 'ev_subscription', 'Подписка не скачивается, трафик и срок',
			'Подписка не скачивается больше суток; израсходовано много трафика; до конца подписки меньше 3 дней.');
		o.default = '1';
		o.rmempty = false;

		o = n.option(form.Value, 'quota_levels', 'Пороги трафика, %', 'Через пробел.');
		o.default = '80 90 95';
		o.depends('ev_subscription', '1');
		o.validate = (id, v) => !v || /^(\d{1,2}|100)( (\d{1,2}|100))*$/.test(v.trim()) || 'Числа от 1 до 100 через пробел';

		o = n.option(form.Button, '_test', ' ');
		o.inputtitle = 'Отправить тестовое сообщение';
		o.inputstyle = 'apply';
		o.onclick = (ev, sid) => {
			const token = val('bot_token', sid), chat = val('chat_id', sid);
			if (!token || !chat) return ui.addNotification(null, E('p', 'Нужны токен бота и ID чата'), 'warning');
			return fs.exec(CLI, ['notify-test', token, chat, val('via_proxy', sid) === '1' ? '1' : '0']).then(res =>
				ui.addNotification(null, E('p', out(res)), res.code === 0 ? 'info' : 'error'));
		};

		return m.render();
	}
});
