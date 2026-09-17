'use strict';
'require view';
'require form';
'require ui';
'require tools.isongwrt as iso';

var CHANNELS = [ 'stable', 'rc', 'beta', 'alpha' ];

function btn(label, style, fn) {
	return E('button', { 'class': 'btn cbi-button cbi-button-' + style, 'click': fn }, label);
}

return view.extend({
	load: function () {
		return iso.call(['installed']);
	},

	render: function (inst) {
		var m, s, o, self = this;
		self.installed = inst || {};
		self.channels = null;

		function latestLine() {
			if (!self.channels)
				return E('span', { 'class': 'cbi-value-description' }, '未检查（点「检查更新」获取官方 Releases 最新版）');
			return E('div', {}, self.channels.map(function (c, i) {
				return [ i ? ' · ' : '', E('strong', {}, c.name), ' ', c.latest || '—' ];
			}).reduce(function (a, b) { return a.concat(b); }, []));
		}

		function installedTable() {
			var versions = (self.installed.versions || []);
			if (!versions.length)
				return E('em', {}, '尚未安装');
			var trs = versions.map(function (v) {
				var isActive = v.version === self.installed.active;
				return E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td left' }, v.version + (isActive ? ' ★' : '')),
					E('td', { 'class': 'td left' }, v.size ? (Math.round(v.size / 1048576 * 10) / 10) + ' MiB' : '-'),
					E('td', { 'class': 'td left' }, isActive ? E('em', {}, '当前') : [
						btn('激活', 'apply', function () {
							return iso.busy(iso.call(['activate', v.version]), '切换内核…').then(function (r) {
								iso.notify(r, '已切换到 ' + v.version);
								return reload();
							});
						}),
						' ',
						btn('删除', 'remove', function () {
							return iso.busy(iso.call(['remove', v.version]), '删除…').then(function (r) {
								iso.notify(r, '已删除 ' + v.version);
								return reload();
							});
						})
					])
				]);
			});
			return E('table', { 'class': 'table' }, trs);
		}

		function reload() {
			return iso.call(['installed']).then(function (r) {
				self.installed = r || {};
				return m.reset();
			});
		}

		function checkUpdates() {
			return iso.busy(iso.call(['channels', 'force']), '正在检查官方 Releases…').then(function (r) {
				if (r && r.ok) {
					self.channels = r.channels || [];
					return m.reset();
				}
				iso.notify(r, '');
			});
		}

		function install() {
			var ch = iso.get('channel', 'stable');
			var pin = (iso.get('pin_version', '') || '').trim();
			var label = pin || (ch + ' 渠道最新版');
			var pre = E('pre', {
				'style': 'max-height:40vh;overflow:auto;white-space:pre-wrap;font-size:12px;background:#111;color:#ddd;padding:8px'
			}, '正在启动安装任务…');
			ui.showModal('安装 ' + label, [ pre, E('div', { 'class': 'right' }, [
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
						ui.hideModal();
						iso.notify({ ok: true }, '安装完成');
						return reload();
					}
					if (r.state === 'failed') {
						stop();
						iso.notify({ ok: false, error: '安装失败，详见进度窗口日志' }, '');
						return reload();
					}
				});
			}

			return iso.call(pin ? [ 'install-bg', ch, pin ] : [ 'install-bg', ch ]).then(function (r) {
				if (!r || !r.ok) { stop(); ui.hideModal(); iso.notify(r, ''); return; }
				timer = setInterval(pollInstall, 3000);
				return pollInstall();
			});
		}

		m = new form.Map('isongwrt', '内核管理',
			'内核取自官方 Releases（SagerNet/sing-box），按本机架构自动匹配、优先 musl 构建；本项目不编译内核。设置改动请先「保存并应用」。');

		s = m.section(form.NamedSection, 'main', 'isongwrt', '安装');
		s.anonymous = true;

		o = s.option(form.ListValue, 'channel', '渠道');
		CHANNELS.forEach(function (c) { o.value(c, c); });
		o.default = 'stable';

		o = s.option(form.Value, 'pin_version', '指定版本',
			'留空 = 渠道最新；也可填精确 tag，如 v1.15.0-alpha.5。');

		o = s.option(form.Value, 'github_proxy', '加速前缀',
			'留空 = 直连 github.com；受限网络可填如 https://ghfast.top/');

		o = s.option(form.DummyValue, '_latest', '最新版本');
		o.cfgvalue = function () { return latestLine(); };

		o = s.option(form.DummyValue, '_actions', '操作');
		o.cfgvalue = function () {
			return E('div', {}, [
				btn('检查更新', 'action', checkUpdates),
				' ',
				btn('安装 / 升级', 'apply', install),
				' ',
				btn('回滚', 'reset', function () {
					return iso.busy(iso.call(['rollback']), '回滚内核…').then(function (r) {
						iso.notify(r, '已回滚');
						return reload();
					});
				})
			]);
		};

		s = m.section(form.TableSection, 'installed', '已安装版本');
		s.anonymous = true;
		o = s.option(form.DummyValue, '_installed');
		o.cfgvalue = function () { return installedTable(); };

		return m.render();
	}
});
