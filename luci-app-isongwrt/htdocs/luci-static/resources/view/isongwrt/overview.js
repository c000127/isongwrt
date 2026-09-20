'use strict';
'require view';
'require form';
'require poll';
'require tools.isongwrt as iso';

function btn(label, style, fn) {
	return E('button', { 'class': 'btn cbi-button cbi-button-' + style, 'click': fn }, label);
}

return view.extend({
	load: function () {
		return iso.call(['status']);
	},

	render: function (status) {
		var m, s, o, self = this;
		self.status = status || {};

		function signature(st) {
			st = st || {};
			return [ st.running, st.pid, st.enabled, st.version, st.active, st.core_installed,
				st.channel, st.arch, st.core_path, st.conf_dir, st.conf_files,
				st.api, st.api_port_busy, st.dashboard, st.config_check ].join('|');
		}
		var lastSig = signature(self.status);
		var dirty = false;
		var staleHint = null;

		/* Re-render the form from UCI, but never while the user has unsaved edits:
		   m.reset() would discard them without asking. */
		function refreshStatusView() {
			if (dirty) {
				if (staleHint) {
					staleHint.textContent =
						'Status changed — save or discard your edits to refresh the values on this page.';
					staleHint.style.display = '';
				}
				return Promise.resolve();
			}
			return m.reset();
		}

		function act(args, label) {
			return iso.busy(iso.call(args), label + '…').then(function (r) {
				iso.notify(r, label + ' 完成');
				return iso.call(['status']).then(function (st) {
					self.status = st || {};
					lastSig = signature(self.status);
					return refreshStatusView();
				});
			});
		}

		function value(fn) {
			return function () { return fn(self.status || {}); };
		}

		function runningText(st) {
			if (st.running)
				return E('span', { 'style': 'color:green' }, '运行中 (PID ' + (st.pid || '?') + ')');
			var why = (st.enabled === true) ? '已启用，未运行' : '未启用';
			return E('span', {}, [ E('span', { 'style': 'color:red' }, '已停止'), '（' + why + '）' ]);
		}

		function checkText(st) {
			if (st.config_check === 'ok') return E('span', { 'style': 'color:green' }, '通过');
			if (st.config_check === 'n/a') return E('span', { 'style': 'color:#888' }, '未安装内核');
			return E('span', { 'style': 'color:red' }, '未通过（见「日志」页）');
		}

		function apiText(st) {
			var t = (st.api || '-');
			if (st.dashboard) t += '，官方面板已启用';
			return t;
		}

		function warnText(st) {
			if (st.api_port_conflict)
				return E('span', { 'style': 'color:#c60' },
					'Same port as an inbound in your config: the core exits right after start — change the API port on the 面板 page.');
			if (st.api_port_busy)
				return E('span', { 'style': 'color:#c60' }, 'API 端口被占用：请到「面板」页改用其它端口，否则内核无法启动');
			if (st.core_installed === false)
				return E('span', { 'style': 'color:#c60' }, '未安装内核：请到「内核管理」安装（官方 Releases）');
			return '—';
		}

		m = new form.Map('isongwrt', 'isongwrt', 'sing-box 内核管理与配置面板。');

		/* 用 NamedSection（指向已存在的 main 段）→ 每个项目独占一行，纵向显示；
		   TableSection 会把选项当“列”渲染成横向表头，故不适用。 */
		s = m.section(form.NamedSection, 'main', 'isongwrt', '状态');

		o = s.option(form.DummyValue, '_running', '运行状态');
		o.cfgvalue = value(function (st) { return runningText(st); });

		o = s.option(form.DummyValue, '_version', '内核版本');
		o.cfgvalue = value(function (st) {
			return st.version ? ('v' + String(st.version).replace(/^v/, '')) : E('em', {}, '未安装');
		});

		o = s.option(form.DummyValue, '_active', '激活版本');
		o.cfgvalue = value(function (st) { return st.active || '—'; });

		o = s.option(form.DummyValue, '_channel', '渠道 / 架构');
		o.cfgvalue = value(function (st) { return (st.channel || '—') + ' / ' + (st.arch || '—'); });

		o = s.option(form.DummyValue, '_core_path', '内核路径');
		o.cfgvalue = value(function (st) { return st.core_path || '—'; });

		o = s.option(form.DummyValue, '_conf_dir', '配置目录');
		o.cfgvalue = value(function (st) { return (st.conf_dir || '—') + '（' + (st.conf_files || 0) + ' 个分片文件）'; });

		o = s.option(form.DummyValue, '_check', '配置校验');
		o.cfgvalue = value(function (st) { return checkText(st); });

		o = s.option(form.DummyValue, '_api', 'API / 面板');
		o.cfgvalue = value(function (st) { return apiText(st); });

		o = s.option(form.DummyValue, '_warn', '提示');
		o.cfgvalue = value(function (st) { return warnText(st); });

		o = s.option(form.DummyValue, '_actions', '服务操作');
		o.cfgvalue = function () {
			return E('div', {}, [
				btn('启动', 'apply', function () { return act(['service', 'start'], '启动服务'); }),
				' ',
				btn('停止', 'reset', function () { return act(['service', 'stop'], '停止服务'); }),
				' ',
				btn('重启', 'action', function () { return act(['service', 'restart'], '重启服务'); })
			]);
		};

		s = m.section(form.NamedSection, 'main', 'isongwrt', '设置');
		o = s.option(form.Flag, 'enabled', '开机自启', '随系统启动并自动拉起。');

		poll.add(function () {
			return iso.call(['status']).then(function (st) {
				st = st || {};
				var sig = signature(st);
				if (sig === lastSig)
					return;
				lastSig = sig;
				self.status = st;
				return refreshStatusView();
			});
		}, 5);

		return m.render().then(function (mapNode) {
			/* Any widget edit marks the form dirty; it is cleared on save / reset */
			mapNode.addEventListener('change', function () { dirty = true; });
			mapNode.addEventListener('input', function () { dirty = true; });

			staleHint = E('div', { 'class': 'cbi-section', 'style': 'color:#c60;display:none' }, '');

			/* Wrap the shared handlers so a successful save/reset clears the flag */
			var clearDirty = function (fn) {
				return function (ev, mode) {
					return Promise.resolve(fn.call(iso, ev, mode)).then(function (r) {
						dirty = false;
						staleHint.style.display = 'none';
						return r;
					});
				};
			};
			self.handleSave = clearDirty(iso.handleSave);
			self.handleSaveApply = clearDirty(iso.handleSaveApply);
			self.handleReset = function (ev) {
				dirty = false;
				staleHint.style.display = 'none';
				return view.prototype.handleReset.call(self, ev);
			};

			return E('div', {}, [ staleHint, mapNode ]);
		});
	}
});
