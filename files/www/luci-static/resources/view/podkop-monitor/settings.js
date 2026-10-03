'use strict';
'require view';
'require form';
'require uci';

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

		return m.render();
	}
});
