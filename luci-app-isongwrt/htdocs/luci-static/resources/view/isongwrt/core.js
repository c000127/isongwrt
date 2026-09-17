'use strict';
'require view';
'require form';
'require dom';
'require ui';
'require tools.isongwrt as iso';

var CHANNELS = [ 'stable', 'rc', 'beta', 'alpha' ];

return view.extend({
	load: function () {
		return Promise.all([ iso.call(['installed']), iso.call(['status']) ]);
	},

	render: function (data) {
		var m, s, o, self = this;

		self.installed = data[0] || {};
		self.status = data[1] || {};
		self.channels = null;

		/* ---------- 表格渲染 ---------- */
		function channelTable(list) {
			var trs = [ E('tr', { 'class': 'tr table-titles' }, [
				E('th', { 'class': 'th' }, '渠道'),
				E('th', { 'class': 'th' }, '最新版本'),
				E('th', { 'class': 'th' }, '状态')
			]) ];
			list.forEach(function (c) {
				var isCurrent = c.latest && self.installed.active === c.latest.replace(/^v/, '');
				trs.push(E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td left' }, c.name),
					E('td', { 'class': 'td left' }, c.latest || E('em', {}, '（该渠道近期无版本）')),
					E('td', { 'class': 'td left' }, isCurrent ? E('span', { 'style': 'color:green' }, '已是最新') : '')
				]));
			});
			return E('table', { 'class': 'table' }, trs);
		}

		function installedTable(inst) {
			var versions = inst.versions || [];
			var trs = [ E('tr', { 'class': 'tr table-titles' }, [
				E('th', { 'class': 'th' }, '版本'),
				E('th', { 'class': 'th' }, '大小'),
				E('th', { 'class': 'th' }, 'SHA256'),
				E('th', { 'class': 'th' }, '操作')
			]) ];
			if (!versions.length)
				trs.push(E('tr', { 'class': 'tr' }, [ E('td', { 'class': 'td', 'colspan': 4 }, '尚未安装任何内核') ]));
			versions.forEach(function (v) {
				var isActive = v.version === inst.active;
				trs.push(E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td left' }, v.version + (isActive ? ' ★' : '')),
					E('td', { 'class': 'td left' }, v.size ? (Math.round(v.size / 1048576 * 10) / 10) + ' MiB' : '-'),
					E('td', { 'class': 'td left' }, (v.sha256 || '').substr(0, 16)),
					E('td', { 'class': 'td left' }, [
						isActive ? E('em', {}, '当前激活') : E('button', {
							'class': 'btn cbi-button cbi-button-apply',
							'click': function () {
								return iso.busy(iso.call(['activate', v.version]), '切换内核…').then(function (r) {
									iso.notify(r, '已切换到 ' + v.version);
									return reloadInstalled();
								});
							}
						}, '激活'),
						' ',
						isActive ? '' : E('button', {
							'class': 'btn cbi-button cbi-button-remove',
							'click': function () {
								return iso.busy(iso.call(['remove', v.version]), '删除…').then(function (r) {
									iso.notify(r, '已删除 ' + v.version);
									return reloadInstalled();
								});
							}
						}, '删除')
					])
				]));
			});
			return E('table', { 'class': 'table' }, trs);
		}

		function reloadInstalled() {
			return iso.call(['installed']).then(function (inst) {
				self.installed = inst || {};
				var el = document.getElementById('iso-installed');
				if (el) dom.content(el, installedTable(self.installed));
				if (self.channels) {
					var ce = document.getElementById('iso-channels');
					if (ce) dom.content(ce, channelTable(self.channels));
				}
			});
		}

		/* ---------- 动作 ---------- */
		function checkUpdates() {
			return iso.busy(iso.call(['channels', 'force']), '正在检查官方 Releases…').then(function (r) {
				if (!r || !r.ok) { iso.notify(r, ''); return; }
				self.channels = r.channels || [];
				var el = document.getElementById('iso-channels');
				if (el) dom.content(el, channelTable(self.channels));
				iso.notify({ ok: true }, '已获取各分支最新版本');
			});
		}

		function install() {
			var ch = iso.get('channel', 'stable');
			var pin = (iso.get('pin_version', '') || '').trim();
			var label = pin ? ('安装 ' + pin) : ('安装 ' + ch + ' 渠道最新版');
			var pre = E('pre', {
				'style': 'max-height:40vh;overflow:auto;white-space:pre-wrap;font-size:12px;background:#111;color:#ddd;padding:8px'
			}, '正在启动安装任务…');
			ui.showModal(label, [ pre, E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, '关闭')
			]) ]);

			var timer = null;
			function stop() { if (timer) { clearInterval(timer); timer = null; } }
			function pollInstall() {
				return iso.call(['install-status']).then(function (r) {
					pre.textContent = (r && r.log) || '(无输出)';
					pre.scrollTop = pre.scrollHeight;
					if (!r || r.state === 'done') {
						stop();
						iso.notify({ ok: true }, label + ' 完成');
						return reloadInstalled();
					}
					if (r.state === 'failed') {
						stop();
						iso.notify({ ok: false, error: '安装失败，详见日志' }, '');
						return reloadInstalled();
					}
				});
			}

			return iso.call(pin ? [ 'install-bg', ch, pin ] : [ 'install-bg', ch ]).then(function (r) {
				if (!r || !r.ok) { stop(); ui.hideModal(); iso.notify(r, ''); return; }
				timer = setInterval(pollInstall, 3000);
				return pollInstall();
			});
		}

		function rollback() {
			return iso.busy(iso.call(['rollback']), '回滚内核…').then(function (r) {
				iso.notify(r, '已回滚');
				return reloadInstalled();
			});
		}

		/* ---------- 表单 ---------- */
		m = new form.Map('isongwrt', '内核管理',
			'内核一律取自官方 Releases（SagerNet/sing-box），按本机架构自动匹配并优先 musl 构建；' +
			'本项目不编译内核。下方设置改动后请先「保存并应用」，再执行安装等操作。');

		s = m.section(form.NamedSection, 'main', 'isongwrt', '安装设置');
		s.anonymous = true;

		o = s.option(form.ListValue, 'channel', '渠道');
		CHANNELS.forEach(function (c) { o.value(c, c); });
		o.default = 'stable';

		o = s.option(form.Value, 'pin_version', '指定版本（可选）',
			'留空 = 安装所选渠道的最新版；也可填精确 tag，例如 v1.15.0-alpha.5。');

		o = s.option(form.Value, 'github_proxy', 'GitHub 加速前缀',
			'留空 = 直连 github.com；网络受限时可填加速前缀，例如 https://ghfast.top/');

		o = s.option(form.Button, 'check');
		o.inputstyle = 'action';
		o.inputtitle = '检查更新';
		o.onclick = checkUpdates;

		o = s.option(form.Button, 'install');
		o.inputstyle = 'apply';
		o.inputtitle = '安装 / 升级';
		o.onclick = install;

		o = s.option(form.Button, 'rollback');
		o.inputstyle = 'reset';
		o.inputtitle = '回滚到上一版本';
		o.onclick = rollback;

		s = m.section(form.TableSection, 'available', '各分支最新版本');
		s.anonymous = true;
		o = s.option(form.DummyValue, '_channels');
		o.cfgvalue = function () {
			return E('div', { 'id': 'iso-channels' },
				self.channels ? channelTable(self.channels) : E('em', {}, '点击上方「检查更新」从官方 Releases 获取'));
		};

		s = m.section(form.TableSection, 'installed', '已安装版本');
		s.anonymous = true;
		o = s.option(form.DummyValue, '_installed');
		o.cfgvalue = function () {
			return E('div', { 'id': 'iso-installed' }, installedTable(self.installed));
		};

		return m.render();
	}
});
