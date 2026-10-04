'use strict';
'require view';
'require fs';
'require ui';
'require uci';
'require poll';

const RUN = '/tmp/podkop-monitor';
const CLI = '/usr/bin/podkop-monitor';
const SUB = '_sub';
const PALETTE = ['#2563eb', '#16a34a', '#d97706', '#9333ea', '#dc2626', '#0891b2', '#db2777', '#65a30d'];
const C = { ok: '#16a34a', warn: '#d97706', bad: '#dc2626', none: '#9ca3af' };

const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
const cls = ms => ms < 0 ? 'bad' : ms < 400 ? 'ok' : ms < 900 ? 'warn' : 'bad';
const fmt = ms => ms < 0 ? '—' : ms + ' мс';
const chips = html => html ? `<div class="pm-chips">${html}</div>` : '';
const upCls = up => up === null ? '' : up >= 99 ? 'ok' : up >= 90 ? 'warn' : 'bad';
const dt = ts => new Date(ts * 1000).toLocaleString('ru');
// та же метка, что pm_target_label в common.sh
const label = url => /149\.154\.167\.51/.test(url) ? 'Telegram DC2' : /149\.154\.167\.91/.test(url) ? 'Telegram DC4'
	: /youtube\.com/.test(url) ? 'youtube.com' : url.replace(/^[a-z]+:\/\//, '').replace(/\/.*/, '');

const CSS = `
.pm-card { border: 1px solid rgba(128,128,128,.3); border-radius: 8px; padding: 12px 14px; margin-bottom: 16px; }
.pm-card h3 { margin: 0 0 8px; font-size: 1.1em; display: flex; flex-wrap: wrap; gap: 4px 12px; align-items: baseline; }
.pm-muted { opacity: .65; font-weight: normal; font-size: .9em; }
.pm-wrap { overflow-x: auto; }
.pm-t { border-collapse: collapse; width: 100%; font-variant-numeric: tabular-nums; }
.pm-t th, .pm-t td { text-align: right; padding: 5px 8px; border-bottom: 1px solid rgba(128,128,128,.2); white-space: nowrap; }
.pm-t th:first-child, .pm-t td:first-child { text-align: left; }
.pm-t th { font-size: .85em; opacity: .7; font-weight: 600; }
.pm-ok { color: ${C.ok}; } .pm-warn { color: ${C.warn}; } .pm-bad { color: ${C.bad}; }
.pm-dot { display: inline-block; width: 8px; height: 8px; border-radius: 50%; margin-right: 6px; vertical-align: middle; }
.pm-tag { font-size: .75em; border: 1px solid currentColor; border-radius: 4px; padding: 0 4px; margin-left: 6px; opacity: .8; }
/* история — одной ширины во всех таблицах, сколько бы колонок ни было в секции */
.pm-card { --pm-hist: clamp(160px, 26vw, 320px); --pm-name: clamp(150px, 18vw, 230px); }
.pm-t th.pm-name, .pm-t td.pm-name { width: var(--pm-name); min-width: var(--pm-name); max-width: var(--pm-name); white-space: normal; text-align: left; }
.pm-t th.pm-hist, .pm-t td.pm-hist { width: var(--pm-hist); min-width: var(--pm-hist); max-width: var(--pm-hist); text-align: left; }
.pm-strip { display: flex; gap: 1px; height: 14px; width: var(--pm-hist); }
.pm-strip i { flex: 1; min-width: 1px; }
.pm-chips { margin: 3px 0 0 14px; display: flex; flex-wrap: wrap; gap: 4px; }
.pm-chips .pm-tag { margin: 0; font-weight: normal; }
.pm-bar { display: flex; flex-wrap: wrap; gap: 8px 16px; align-items: center; margin-bottom: 14px; }
.pm-bar .pm-sp { flex: 1; }
.pm-btns { display: flex; flex-wrap: wrap; gap: 6px; margin: 10px 0 4px; align-items: center; }
.pm-btns .cbi-button.on { outline: 2px solid ${PALETTE[0]}; }
.pm-update { border-color: ${C.warn}; }
.pm-tag.pm-bad, .pm-tag.pm-warn { opacity: 1; font-weight: 600; }
.pm-tag.pm-gray { opacity: .55; }
.pm-fix { cursor: pointer; }
.pm-fix:hover { text-decoration: underline; }
.pm-diff td, .pm-diff th { padding: 4px 10px 4px 0; text-align: left; vertical-align: top; }
.pm-diff .old { opacity: .6; text-decoration: line-through; }
.pm-t td.pm-cb, .pm-t th.pm-cb { width: 22px; min-width: 22px; max-width: 22px; padding-right: 0; text-align: left; }
.pm-t td.pm-cb + td, .pm-t th.pm-cb + th { text-align: left; }
.pm-actions { display: flex; flex-wrap: wrap; gap: 6px; align-items: center; margin: 8px 0 0; }
.pm-pick { list-style: none; padding: 0; margin: 8px 0; max-height: 50vh; overflow: auto; }
.pm-pick li { padding: 4px 0; }
.pm-pick label { display: flex; gap: 8px; align-items: baseline; cursor: pointer; }
.pm-sort { cursor: pointer; user-select: none; }
.pm-sort:hover, .pm-sort.on { opacity: 1 !important; text-decoration: underline; }
.pm-chart .u-legend { font-size: .85em; }
`;

// Подключить скрипт/стиль. Не ждём дольше 3 с: onload у стилей приходит не всегда (например, из кеша),
// а без графиков страница всё равно работает.
function loadAsset(tag, attrs) {
	return new Promise(resolve => {
		const el = document.createElement(tag);
		el.onload = el.onerror = resolve;
		Object.assign(el, attrs);
		document.head.appendChild(el);
		setTimeout(resolve, 3000);
	});
}

// Серверы везде сопоставляются по имени: номер в секции или подписке сдвигается, когда серверы
// добавляют и удаляют, а история должна оставаться у своего сервера. sv.key — номер в последнем замере.
function parseData(text) {
	const secs = {}, at = new Map();
	for (const l of (text || '').split('\n')) {
		if (!l) continue;
		const [ts, sec, key, name, target, ms] = l.split(',');
		const s = secs[sec] ??= { servers: {}, targets: [], nowRaw: [], lastTs: 0 };
		s.lastTs = Math.max(s.lastTs, +ts);
		if (target === 'now') { s.nowRaw.push([+ts, key]); continue; }
		if (!s.targets.includes(target)) s.targets.push(target);
		at.set(`${sec}|${ts}|${key}`, name);
		const sv = s.servers[name] ??= { name, pts: {}, lastTs: 0, key: +key };
		if (+ts >= sv.lastTs) { sv.lastTs = +ts; sv.key = +key; }
		(sv.pts[target] ??= []).push([+ts, +ms]);
	}
	// выбранный автовыбором сервер: номер на момент замера → имя
	for (const [sec, s] of Object.entries(secs))
		s.now = s.nowRaw.map(([ts, key]) => [ts, at.get(`${sec}|${ts}|${key}`)]);
	return secs;
}

function stats(pts, since) {
	const win = (pts || []).filter(p => p[0] >= since);
	const okv = win.filter(p => p[1] >= 0).map(p => p[1]).sort((a, b) => a - b);
	return {
		win,
		up: win.length ? Math.round(100 * okv.length / win.length) : null,
		med: okv.length ? okv[Math.floor(okv.length / 2)] : -1,
		last: (pts || []).at(-1)
	};
}

const strip = win => `<div class="pm-strip">${win.map(p =>
	`<i style="background:${C[cls(p[1])]}" title="${dt(p[0])}: ${fmt(p[1])}"></i>`).join('')}</div>`;

return view.extend({
	rangeH: 24,
	plots: [],
	sel: {},  // секция → Set имён отмеченных серверов (переживает перерисовку)

	load() {
		document.head.appendChild(Object.assign(document.createElement('style'), { textContent: CSS }));
		return Promise.all([
			window.uPlot ? null : Promise.all([
				loadAsset('link', { rel: 'stylesheet', href: L.resource('podkop-monitor/uPlot.min.css') }),
				loadAsset('script', { src: L.resource('podkop-monitor/uPlot.iife.min.js') })
			]).catch(() => null),
			uci.load('podkop'),
			uci.load('podkop-monitor')
		]).then(() => this.fetchData());
	},

	fetchData() {
		return Promise.all([
			L.resolveDefault(fs.read_direct(RUN + '/data.csv', 'text'), ''),
			L.resolveDefault(fs.read_direct(RUN + '/country.csv', 'text'), ''),
			L.resolveDefault(fs.read(RUN + '/update.json').then(JSON.parse), null),
			L.resolveDefault(fs.read('/usr/libexec/podkop-monitor/VERSION'), '?'),
			L.resolveDefault(fs.read(RUN + '/drift.csv'), ''),
			L.resolveDefault(fs.read(RUN + '/auto.log'), ''),
			L.resolveDefault(fs.read(RUN + '/skipped.tsv'), '')
		]).then(([data, country, update, version, drift, auto, skipped]) => {
			// записи подписки, которые мониторинг не может проверить: [{ name, why }]
			this.skipped = skipped.split('\n').filter(Boolean).map(l => { const [name, why] = l.split('|'); return { name, why }; });
			// журнал автообновления: время|имя;имя;|режим
			this.auto = auto.split('\n').filter(Boolean).map(l => {
				const [ts, names] = l.split('|');
				return { ts: +ts, names: names.split(';').filter(Boolean) };
			});
			// сверка ссылок podkop с подпиской: drift[section][key] = { status, fields }
			this.drift = {};
			for (const l of drift.split('\n').filter(Boolean)) {
				const [sec, key, name, status, fields] = l.split(',');
				(this.drift[sec] ??= {})[+key] = { name, status,
					fields: fields ? fields.split(';').map(f => { const [field, from, to] = f.split('|'); return { field, from, to }; }) : [] };
			}
			this.data = parseData(data);
			this.country = {};
			this.countryTs = 0;
			for (const l of country.split('\n').filter(Boolean)) {
				const [ts, key, name, gl, ip] = l.split(',');
				this.country[name] = { gl, ip };
				this.countryTs = +ts;
			}
			this.update = update;
			this.version = version.trim();
		});
	},

	// --- фоновые команды (check, sub-update, upgrade) ---
	runBg(cmd, title, reload, args) {
		ui.showModal(title, [E('p', { 'class': 'spinning' }, 'Выполняется, это может занять до минуты…')]);
		const started = Date.now();
		return fs.exec(CLI, ['bg', cmd].concat(args || [])).then(() => new Promise(resolve => {
			const tick = () => L.resolveDefault(fs.read(`${RUN}/${cmd}.rc`), null).then(rc => {
				if (rc === null && Date.now() - started < 300000) return setTimeout(tick, 2000);
				return L.resolveDefault(fs.read(`${RUN}/${cmd}.log`), '').then(log => {
					ui.showModal(title, [
						E('pre', { 'style': 'max-height:300px;overflow:auto;white-space:pre-wrap' }, log || (rc === null ? 'Нет ответа' : 'Готово')),
						E('div', { 'class': 'right' }, E('button', {
							'class': 'cbi-button cbi-button-positive',
							'click': () => { ui.hideModal(); reload ? location.reload() : this.refresh(); }
						}, 'OK'))
					]);
					resolve();
				});
			});
			setTimeout(tick, 2000);
		}));
	},

	checkUpdates() {
		return fs.exec(CLI, ['update-check']).then(() => this.refresh());
	},

	refresh() {
		return this.fetchData().then(() => this.draw());
	},

	// --- отрисовка ---
	renderVersion() {
		const u = this.update;
		const avail = u && u.available;
		const checked = u ? `проверено ${dt(u.checked)}` : 'обновления ещё не проверялись';
		const latest = u && u.latest ? (avail ? `доступна ${esc(u.latest)}` : 'последняя версия') : (u && u.error ? esc(u.error) : '');
		const box = E('div', { 'class': 'pm-card pm-bar' + (avail ? ' pm-update' : '') }, [
			E('span', {}, [E('strong', {}, 'podkop-monitor ' + this.version)]),
			E('span', { 'class': avail ? 'pm-warn' : 'pm-muted' }, latest),
			E('span', { 'class': 'pm-muted' }, checked),
			E('span', { 'class': 'pm-sp' }),
			avail && u.page ? E('a', { 'href': u.page, 'target': '_blank', 'rel': 'noopener' }, 'Что нового') : '',
			E('button', { 'class': 'cbi-button', 'click': ui.createHandlerFn(this, 'checkUpdates') }, 'Проверить обновления'),
			avail ? E('button', {
				'class': 'cbi-button cbi-button-positive',
				'click': ui.createHandlerFn(this, () => this.runBg('upgrade', `Обновление до ${u.latest}`, true))
			}, `Обновить до ${u.latest}`) : ''
		]);
		return box;
	},

	sectionMain(sec) {
		if (sec === SUB) return 'www.gstatic.com';
		return label(uci.get('podkop', sec, 'urltest_testing_url') || 'https://www.gstatic.com/generate_204');
	},

	// отметка о расхождении ссылки в podkop с подпиской
	driftTag(sec, k, sv, lastMs) {
		const d = this.drift[sec]?.[k];
		if (!d || d.status === 'same') return '';
		if (d.status === 'unsupported')
			return `<span class="pm-tag pm-gray" title="Есть в подписке, но мониторинг не может его проверить: ${esc(d.fields.map(f => f.field).join(', '))}">не поддерживается</span>`;
		if (d.status === 'missing')
			return '<span class="pm-tag pm-gray" title="Сервера с таким именем нет в подписке: ссылка своя, переименована или сервер удалён">нет в подписке</span>';
		const what = 'Отличается от подписки: ' + d.fields.map(f => f.field).join(', ');
		const attrs = `class="pm-tag pm-fix pm-%s" data-name="${esc(sv.name)}" title="%s Нажмите, чтобы заменить ссылку в podkop ссылкой из подписки."`;
		// через podkop не отвечает, а по ссылке из подписки — отвечает: ссылка устарела
		const sub = this.data[SUB]?.servers[sv.name];
		const subLast = sub?.pts['www.gstatic.com']?.at(-1);
		if (lastMs < 0 && subLast && subLast[1] >= 0)
			return `<span ${attrs.replace('%s', 'bad').replace('%s', esc(`${what}. Через podkop не отвечает, по ссылке из подписки — ${subLast[1]} мс.`))}>устарел ↻</span>`;
		return `<span ${attrs.replace('%s', 'warn').replace('%s', esc(`${what}. Пока работает, но старая ссылка может перестать работать.`))}>изменён в подписке ↻</span>`;
	},

	// серверы секции с расхождением: [{ name, d }]
	driftList(sec) {
		return Object.values(this.drift[sec] || {}).filter(d => d.status === 'differs').map(d => ({ name: d.name, d }));
	},

	diffTable(d) {
		return E('table', { 'class': 'pm-diff' }, [
			E('tr', {}, [E('th', {}, 'Параметр'), E('th', {}, 'Сейчас в podkop'), E('th', {}, 'В подписке')])
		].concat(d.fields.map(f => E('tr', {}, [
			E('td', {}, f.field),
			E('td', { 'class': 'old' }, f.from || 'прежний'),
			E('td', {}, f.to || 'новый')
		]))));
	},

	PODKOP_NOTE: 'Перед правкой сохраняется копия конфига podkop (/etc/podkop-monitor/podkop.backup-…). ' +
		'podkop перезапустится — на несколько секунд пропадёт доступ к сайтам через прокси.',

	// диалог со списком серверов и галочками; onOk(выбранные имена)
	pickDialog(title, intro, items, okLabel, onOk, note, danger) {
		const boxes = items.map(it => E('input', { 'type': 'checkbox', 'checked': it.checked !== false ? '' : null, 'value': it.name }));
		const ok = E('button', { 'class': 'cbi-button ' + (danger ? 'cbi-button-negative' : 'cbi-button-positive') }, okLabel);
		const sync = () => { const n = boxes.filter(b => b.checked).length; ok.disabled = !n; ok.textContent = `${okLabel} (${n})`; };
		boxes.forEach(b => b.addEventListener('change', sync));
		ok.addEventListener('click', () => onOk(boxes.filter(b => b.checked).map(b => b.value)));
		sync();
		ui.showModal(title, [
			E('p', {}, intro),
			E('ul', { 'class': 'pm-pick' }, items.map((it, i) => E('li', {}, E('label', {}, [boxes[i], E('span', {}, [E('strong', {}, it.name), it.detail ? E('div', { 'class': 'pm-muted' }, it.detail) : ''])])))),
			E('p', { 'class': 'pm-muted' }, note || this.PODKOP_NOTE),
			E('div', { 'class': 'right' }, [E('button', { 'class': 'cbi-button', 'click': ui.hideModal }, 'Отмена'), ' ', ok])
		]);
	},

	confirmApplyAll(sec) {
		const list = this.driftList(sec);
		this.pickDialog(`Обновить серверы секции ${sec} из подписки`,
			'Ссылки отмеченных серверов будут заменены ссылками из подписки. Снимите галочку с тех, что вы меняли намеренно (например, SNI) — их правки пропадут.',
			list.map(({ name, d }) => ({ name, detail: d.fields.map(f => f.from ? `${f.field}: ${f.from} → ${f.to}` : `${f.field}: изменён`).join('; ') })),
			'Обновить', names => this.runBg('apply', `Обновление секции ${sec}`, false, [sec].concat(names)));
	},

	confirmRemove(sec, s) {
		const names = [...(this.sel[sec] || [])];
		const all = Object.values(s.servers).filter(v => v.lastTs >= s.lastTs).length;
		const cur = s.now.at(-1)?.[1];
		if (names.length >= all)
			return ui.addNotification(null, E('p', {}, 'Нельзя убрать из секции все серверы — podkop не запустится. Оставьте хотя бы один.'), 'warning');
		this.pickDialog(`Убрать серверы из секции ${sec}?`,
			'Отмеченные серверы будут удалены из конфигурации podkop (в подписке и в общем списке ниже они останутся).',
			names.map(name => ({ name, detail: name === cur ? 'сейчас выбран автовыбором — podkop переключится на другой' : '' })),
			'Удалить', picked => { this.sel[sec] = new Set(); this.runBg('remove', `Удаление из секции ${sec}`, false, [sec].concat(picked)); }, null, true);
	},

	confirmApply(sec, name) {
		const d = Object.values(this.drift[sec] || {}).find(x => x.name === name);
		if (!d) return;
		ui.showModal(`Обновить «${d.name}» в секции ${sec}?`, [
			E('p', {}, 'Ссылка в podkop будет заменена ссылкой этого сервера из подписки:'),
			this.diffTable(d),
			E('p', { 'class': 'pm-muted' }, this.PODKOP_NOTE + ' Если вы меняли эту ссылку намеренно (например, SNI), ваши правки пропадут.'),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'cbi-button', 'click': ui.hideModal }, 'Отмена'), ' ',
				E('button', {
					'class': 'cbi-button cbi-button-positive',
					'click': () => this.runBg('apply', `Обновление «${d.name}»`, false, [sec, d.name])
				}, 'Заменить')
			])
		]);
	},

	renderSection(sec, s, since) {
		const main = this.sectionMain(sec);
		const targets = s.targets.slice().sort((a, b) => (a === main) - (b === main) || a.localeCompare(b));
		const cur = s.now.at(-1);
		// текущие серверы секции (есть в последнем замере) в порядке podkop
		const keys = Object.keys(s.servers).filter(n => s.servers[n].lastTs >= s.lastTs).sort((a, b) => s.servers[a].key - s.servers[b].key);
		const sel = this.sel[sec] ??= new Set();
		[...sel].forEach(n => keys.includes(n) || sel.delete(n));
		const editable = ['urltest', 'selector'].includes(uci.get('podkop', sec, 'proxy_config_type'));
		let html = `<h3>${esc(sec)}<span class="pm-muted">выбран: ${cur && cur[1] ? esc(cur[1]) : '?'}</span></h3>
			<div class="pm-wrap"><table class="pm-t"><tr>${editable ? '<th class="pm-cb"><input type="checkbox" class="pm-all" title="Отметить все"></th>' : ''}<th class="pm-name">Сервер</th><th class="pm-hist">История (${this.rangeH} ч)</th>${
			targets.map(t => `<th>${esc(t)}</th>`).join('')}<th>Доступность</th><th>Медиана</th></tr>`;
		for (const k of keys) {
			const sv = s.servers[k];
			const st = stats(sv.pts[main], since);
			html += `<tr>${editable ? `<td class="pm-cb"><input type="checkbox" class="pm-sel" data-name="${esc(k)}"${sel.has(k) ? ' checked' : ''}></td>` : ''}<td class="pm-name"><span class="pm-dot" style="background:${C[cls(st.last ? st.last[1] : -1)]}"></span>${esc(sv.name)}${
				chips((cur && cur[1] === k ? '<span class="pm-tag">выбран</span>' : '') + this.driftTag(sec, sv.key, sv, st.last ? st.last[1] : -1))}</td>
				<td class="pm-hist">${strip(st.win)}</td>`;
			for (const t of targets) {
				const p = (sv.pts[t] || []).at(-1);
				html += `<td class="pm-${cls(p ? p[1] : -1)}">${fmt(p ? p[1] : -1)}</td>`;
			}
			html += `<td class="pm-${upCls(st.up)}">${st.up === null ? '—' : st.up + '%'}</td><td>${fmt(st.med)}</td></tr>`;
		}
		html += `</table></div>`;
		if (this.drift[sec] && Object.values(this.drift[sec]).some(d => d.status !== 'same'))
			html += `<p class="pm-muted" style="margin:6px 0 0">Ссылки сверяются с подпиской по имени сервера.
				<b>устарел</b> — через podkop не отвечает, а по ссылке из подписки отвечает;
				<b>изменён в подписке</b> — провайдер поменял параметры, но старая ссылка пока работает.
				Нажмите на отметку, чтобы посмотреть отличия и заменить ссылку в podkop.</p>`;

		const card = E('div', { 'class': 'pm-card' });
		card.innerHTML = html;
		card.querySelectorAll('.pm-fix').forEach(el => el.addEventListener('click', () => this.confirmApply(sec, el.dataset.name)));

		// действия над секцией
		const drifted = this.driftList(sec).length;
		const delBtn = E('button', { 'class': 'cbi-button cbi-button-negative', 'click': () => this.confirmRemove(sec, s) });
		const syncSel = () => {
			delBtn.disabled = !sel.size;
			delBtn.textContent = sel.size ? `Удалить выбранные (${sel.size})` : 'Удалить выбранные';
			const all = card.querySelector('.pm-all');
			if (all) { all.checked = sel.size === keys.length && keys.length > 0; all.indeterminate = sel.size > 0 && sel.size < keys.length; }
		};
		card.querySelectorAll('.pm-sel').forEach(cb => cb.addEventListener('change', () => {
			cb.checked ? sel.add(cb.dataset.name) : sel.delete(cb.dataset.name);
			syncSel();
		}));
		card.querySelector('.pm-all')?.addEventListener('change', e => {
			card.querySelectorAll('.pm-sel').forEach(cb => { cb.checked = e.target.checked; e.target.checked ? sel.add(cb.dataset.name) : sel.delete(cb.dataset.name); });
			syncSel();
		});
		if (editable || drifted) {
			card.appendChild(E('div', { 'class': 'pm-actions' }, [
				editable ? delBtn : '',
				drifted ? E('button', { 'class': 'cbi-button cbi-button-action', 'click': () => this.confirmApplyAll(sec) }, `Обновить из подписки (${drifted})`) : ''
			]));
			syncSel();
		}
		if (window.uPlot) {
			const btns = E('div', { 'class': 'pm-btns' }, [E('span', { 'class': 'pm-muted' }, 'График:')]);
			const chart = E('div', { 'class': 'pm-chart' });
			const draw = t => {
				btns.querySelectorAll('button').forEach(b => b.classList.toggle('on', b.textContent === t));
				this.drawChart(chart, s, keys, t, since);
			};
			targets.forEach(t => btns.appendChild(E('button', { 'class': 'cbi-button', 'click': () => draw(t) }, t)));
			card.appendChild(btns);
			card.appendChild(chart);
			requestAnimationFrame(() => draw(main));
		}
		return card;
	},

	drawChart(el, s, keys, t, since) {
		if (el._plot) { this.plots = this.plots.filter(p => p !== el._plot); el._plot.destroy(); }
		const xsSet = new Set();
		keys.forEach(k => (s.servers[k].pts[t] || []).forEach(p => p[0] >= since && xsSet.add(p[0])));
		const xs = [...xsSet].sort((a, b) => a - b);
		const series = keys.map(k => {
			const m = new Map(s.servers[k].pts[t] || []);
			return xs.map(x => { const v = m.get(x); return v === undefined || v < 0 ? null : v; });
		});
		const fg = getComputedStyle(el).color;
		const axis = { stroke: fg, grid: { stroke: 'rgba(128,128,128,.2)' }, ticks: { stroke: 'rgba(128,128,128,.3)' } };
		const plot = new uPlot({
			width: Math.max(300, el.clientWidth), height: 240,
			scales: { x: { time: true }, y: { range: (u, mn, mx) => [0, Math.max(500, (mx || 0) * 1.1)] } },
			axes: [axis, Object.assign({}, axis, { size: 64, values: (u, v) => v.map(x => x + ' мс') })],
			series: [{}].concat(keys.map((k, i) => ({
				label: s.servers[k].name, stroke: PALETTE[i % PALETTE.length], width: 1.5,
				value: (u, v) => v == null ? '—' : v + ' мс'
			})))
		}, [xs].concat(series), el);
		el._plot = plot;
		this.plots.push(plot);
	},

	// секции podkop, где сейчас стоит сервер с таким именем
	sectionsOf(name) {
		return Object.entries(this.data)
			.filter(([sec, d]) => sec !== SUB && d.servers[name] && d.servers[name].lastTs >= d.lastTs)
			.map(([sec]) => sec);
	},

	// подсказка о сервере подписки для выбранной секции
	addHint(sec, sv) {
		const lists = L.toArray(uci.get('podkop', sec, 'community_lists'));
		const last = t => (sv.pts[t] || []).at(-1)?.[1];
		const hints = [];
		if (last('www.gstatic.com') < 0) hints.push('⚠ сейчас не отвечает');
		if (lists.includes('telegram')) hints.push(`Telegram DC2: ${fmt(last('Telegram DC2') ?? -1)}`);
		if (lists.includes('youtube')) {
			const c = this.country[sv.name];
			hints.push(!c || !c.gl ? 'страна YouTube неизвестна'
				: c.gl === 'RU' ? 'YouTube видит RU — без рекламы' : `⚠ YouTube видит ${c.gl} — будет реклама`);
		}
		hints.push(`gstatic: ${fmt(last('www.gstatic.com') ?? -1)}`);
		return hints.join(' · ');
	},

	confirmAdd(sec) {
		const s = this.data[SUB];
		const names = [...(this.sel[SUB] || [])];
		const already = names.filter(n => this.sectionsOf(n).includes(sec));
		const items = names.filter(n => !already.includes(n)).map(name => {
			const sv = s.servers[name];
			const hint = this.addHint(sec, sv);
			// не отвечающие и «с рекламой» для YouTube — без галочки по умолчанию
			return { name, detail: hint, checked: !hint.includes('⚠') };
		});
		if (!items.length)
			return ui.addNotification(null, E('p', {}, `Все отмеченные серверы уже есть в секции ${sec}.`), 'info');
		this.pickDialog(`Добавить серверы в секцию ${sec}?`,
			`Отмеченные серверы будут добавлены в конец секции ${sec} ссылками из подписки.` +
				(already.length ? ` Уже есть в секции и будут пропущены: ${already.join(', ')}.` : ''),
			items, 'Добавить',
			picked => { this.sel[SUB] = new Set(); this.runBg('add', `Добавление в секцию ${sec}`, false, [sec].concat(picked)); });
	},

	renderSub(s, since) {
		const main = this.sectionMain(SUB);
		const targets = s.targets.slice().sort((a, b) => (a === main) - (b === main) || a.localeCompare(b));
		const sortBy = this.subSort || main;
		const rows = Object.values(s.servers).map(sv => {
			const st = stats(sv.pts[main], since);
			const v = sortBy === main ? st.med : ((sv.pts[sortBy] || []).at(-1)?.[1] ?? -1);
			return { sv, st, v, gone: sv.lastTs < s.lastTs };
		});
		// быстрые сверху, не отвечающие ниже, пропавшие из подписки — в самом низу
		rows.sort((a, b) => a.gone - b.gone || (a.v < 0) - (b.v < 0) || a.v - b.v);
		const live = rows.filter(r => !r.gone).map(r => r.sv.name);
		const sel = this.sel[SUB] ??= new Set();
		[...sel].forEach(n => live.includes(n) || sel.delete(n));
		const yt = uci.get('podkop-monitor', 'main', 'youtube_country') !== '0';
		const secs = uci.sections('podkop', 'section')
			.filter(x => x.connection_type === 'proxy' && ['urltest', 'selector'].includes(x.proxy_config_type))
			.map(x => x['.name']);
		const th = (t, label) => `<th class="pm-sort${sortBy === t ? ' on' : ''}" data-sort="${esc(t)}" title="Сортировать">${esc(label || t)}${sortBy === t ? ' ▲' : ''}</th>`;

		let html = `<h3>Все серверы подписки<span class="pm-muted">${live.length} шт.${
			yt && this.countryTs ? ' · страна YouTube на ' + dt(this.countryTs) : ''}</span></h3>
			<div class="pm-wrap"><table class="pm-t"><tr>${secs.length ? '<th class="pm-cb"><input type="checkbox" class="pm-all" title="Отметить все"></th>' : ''}<th class="pm-name">Сервер</th><th class="pm-hist">История (${this.rangeH} ч)</th>${
			targets.map(t => th(t)).join('')}<th>Доступность</th>${th(main, 'Медиана')}${yt ? '<th>Страна YouTube</th>' : ''}</tr>`;
		for (const { sv, st, gone } of rows) {
			const c = gone ? null : this.country[sv.name];
			const inSecs = this.sectionsOf(sv.name);
			html += `<tr${gone ? ' style="opacity:.5"' : ''}>${secs.length ? `<td class="pm-cb">${gone ? ''
				: `<input type="checkbox" class="pm-sel" data-name="${esc(sv.name)}"${sel.has(sv.name) ? ' checked' : ''}>`}</td>` : ''}<td class="pm-name"><span class="pm-dot" style="background:${
				gone ? C.none : C[cls(st.last ? st.last[1] : -1)]}"></span>${esc(sv.name)}${
				gone ? ` <span class="pm-muted">— нет в подписке с ${new Date(sv.lastTs * 1000).toLocaleDateString('ru')}</span>` : ''}${
				chips(inSecs.map(x => `<span class="pm-tag" title="Уже стоит в секции podkop">${esc(x)}</span>`).join(''))}</td>
				<td class="pm-hist">${strip(st.win)}</td>`;
			for (const t of targets) {
				const p = (sv.pts[t] || []).at(-1);
				html += gone ? '<td>—</td>' : `<td class="pm-${cls(p ? p[1] : -1)}">${fmt(p ? p[1] : -1)}</td>`;
			}
			html += `<td class="pm-${upCls(st.up)}">${st.up === null ? '—' : st.up + '%'}</td><td>${fmt(st.med)}</td>`;
			if (yt) html += !c || !c.gl ? '<td>—</td>'
				: `<td class="pm-${c.gl === 'RU' ? 'ok' : 'warn'}" title="YouTube видит IP ${esc(c.ip)}">${esc(c.gl)} · ${c.gl === 'RU' ? 'без рекламы' : 'реклама'}</td>`;
			html += `</tr>`;
		}
		html += `</table></div>`;
		const card = E('div', { 'class': 'pm-card' });
		card.innerHTML = html;

		card.querySelectorAll('.pm-sort').forEach(h => h.addEventListener('click', () => { this.subSort = h.dataset.sort; this.draw(); }));

		if (secs.length) {
			const pick = E('select', { 'class': 'cbi-input-select' }, secs.map(x => E('option', { 'value': x }, x)));
			if (this.addTo && secs.includes(this.addTo)) pick.value = this.addTo;
			pick.addEventListener('change', () => { this.addTo = pick.value; });
			const addBtn = E('button', { 'class': 'cbi-button cbi-button-add', 'click': () => this.confirmAdd(pick.value) });
			const syncSel = () => {
				addBtn.disabled = !sel.size;
				addBtn.textContent = sel.size ? `Добавить выбранные (${sel.size})` : 'Добавить выбранные';
				const all = card.querySelector('.pm-all');
				if (all) { all.checked = sel.size === live.length && live.length > 0; all.indeterminate = sel.size > 0 && sel.size < live.length; }
			};
			card.querySelectorAll('.pm-sel').forEach(cb => cb.addEventListener('change', () => {
				cb.checked ? sel.add(cb.dataset.name) : sel.delete(cb.dataset.name);
				syncSel();
			}));
			card.querySelector('.pm-all')?.addEventListener('change', e => {
				card.querySelectorAll('.pm-sel').forEach(cb => { cb.checked = e.target.checked; e.target.checked ? sel.add(cb.dataset.name) : sel.delete(cb.dataset.name); });
				syncSel();
			});
			card.appendChild(E('div', { 'class': 'pm-actions' }, [addBtn, E('span', {}, 'в секцию'), pick]));
			syncSel();
		}
		if (this.skipped.length)
			card.appendChild(E('p', { 'class': 'pm-muted', 'style': 'margin:8px 0 0' },
				`Не проверяются (${this.skipped.length}): ` + this.skipped.map(x => `${x.name} — ${x.why}`).join('; ') + '.'));
		card.appendChild(E('p', { 'class': 'pm-muted', 'style': 'margin:8px 0 0' },
			'Нажмите на заголовок колонки, чтобы отсортировать. Доступность и медиана — по gstatic. ' +
			'Если провайдер ведёт YouTube через отдельный сервер, youtube.com и страна YouTube проверяются через него — как в его приложении. ' +
			'Замеры подписки идут через отдельный sing-box и не влияют на автовыбор podkop.'));
		return card;
	},

	draw() {
		const root = this.root;
		this.plots.forEach(p => p.destroy());
		this.plots = [];
		root.innerHTML = '';
		root.appendChild(this.renderVersion());

		const since = Date.now() / 1000 - this.rangeH * 3600;
		const last = Math.max(0, ...Object.values(this.data).map(s => s.lastTs));
		const ranges = E('div', { 'class': 'pm-bar' }, [
			E('span', { 'class': 'pm-muted' }, last ? 'последняя проверка: ' + dt(last) : 'проверок ещё не было'),
			E('span', { 'class': 'pm-sp' }),
			...[[24, '24 ч'], [168, '7 дней']].map(([h, t]) => E('button', {
				'class': 'cbi-button' + (this.rangeH === h ? ' cbi-button-action' : ''),
				'click': () => { this.rangeH = h; this.draw(); }
			}, t)),
			E('button', { 'class': 'cbi-button', 'click': ui.createHandlerFn(this, () => this.runBg('check', 'Проверка серверов')) }, 'Проверить сейчас'),
			uci.get('podkop-monitor', 'main', 'subscription_url')
				? E('button', { 'class': 'cbi-button', 'click': ui.createHandlerFn(this, () => this.runBg('sub-update', 'Обновление подписки')) }, 'Обновить подписку')
				: ''
		]);
		root.appendChild(ranges);

		const mode = uci.get('podkop-monitor', 'main', 'auto_update') || 'off';
		if (mode !== 'off') {
			const last = this.auto[0];
			root.appendChild(E('div', { 'class': 'pm-card pm-bar' }, [
				E('span', {}, [E('strong', {}, 'Автообновление ссылок: '), mode === 'all' ? 'все изменённые' : 'только неработающие']),
				E('span', { 'class': 'pm-muted' }, last
					? `последнее ${dt(last.ts)}: ${last.names.join(', ')}` + (this.auto.length > 1 ? ` (всего замен в журнале: ${this.auto.length})` : '')
					: 'замен пока не было'),
				E('span', { 'class': 'pm-sp' }),
				E('a', { 'href': L.url('admin/services/podkop-monitor/settings') }, 'Настройки')
			]));
		}

		if (!last) {
			root.appendChild(E('p', {}, 'Данных пока нет: первая проверка появится в течение нескольких минут, либо нажмите «Проверить сейчас».'));
			return;
		}
		const order = uci.sections('podkop', 'section').map(s => s['.name']).filter(n => this.data[n]);
		for (const sec of order) root.appendChild(this.renderSection(sec, this.data[sec], since));
		if (this.data[SUB]) root.appendChild(this.renderSub(this.data[SUB], since));
		else if (!uci.get('podkop-monitor', 'main', 'subscription_url'))
			root.appendChild(E('p', { 'class': 'pm-muted' }, 'Чтобы видеть все серверы VPN-провайдера, укажите ссылку на подписку во вкладке «Настройки».'));
	},

	render() {
		this.root = E('div');
		const page = E('div', {}, [
			E('h2', {}, 'Podkop Monitor'),
			E('div', { 'class': 'cbi-map-descr' }, 'Доступность серверов podkop и подписки VPN-провайдера. Время — задержка ответа через сервер, включая установку соединения; «—» — нет ответа.'),
			this.root
		]);
		requestAnimationFrame(() => this.draw());
		poll.add(() => this.refresh(), 300);
		let rt;
		window.addEventListener('resize', () => { clearTimeout(rt); rt = setTimeout(() => this.draw(), 300); });
		return page;
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
