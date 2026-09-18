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
				st.api, st.api_port_busy, st.dashboard, st.clash_api, st.config_check ].join('|');
		}
		var lastSig = signature(self.status);

		function act(args, label) {
			return iso.busy(iso.call(args), label + '…').then(function (r) {
				iso.notify(r, label + ' 完成');
				return iso.call(['status']).then(function (st) {
					self.status = st || {};
					lastSig = signature(self.status);
					return m.reset();
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
			if (st.clash_api) t += '，Clash API 已启用';
			return t;
		}

		function warnText(st) {
			if (st.api_port_conflict)
				return E('span', { 'style': 'color:#c60' },
					'API 端口与配置文件内的 clash_api/入站端口相同：内核会启动后立刻退出，请二选一改端口（配置里改 clash_api，或到「面板」页改 API 端口）');
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
		s.anonymous = true;

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
		s.anonymous = true;
		o = s.option(form.Flag, 'enabled', '开机自启', '随系统启动并自动拉起。');

		poll.add(function () {
			return iso.call(['status']).then(function (st) {
				st = st || {};
				var sig = signature(st);
				if (sig !== lastSig) {
					lastSig = sig;
					self.status = st;
					return m.reset();
				}
			});
		}, 5);

		return m.render();
	}
});
