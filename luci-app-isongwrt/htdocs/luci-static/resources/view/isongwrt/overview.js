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
			return [ st.running, st.pid, st.version, st.config_check, st.api, st.api_port_busy, st.enabled ].join('|');
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

		function statusLine() {
			var st = self.status || {};
			var parts = [];
			parts.push(st.running
				? E('span', { 'style': 'color:green' }, '运行中')
				: E('span', { 'style': 'color:red' }, '已停止'));
			if (st.running)
				parts.push('PID ' + (st.pid || '?'));
			parts.push(st.version ? ('v' + String(st.version).replace(/^v/, '')) : '未安装内核');
			parts.push(st.config_check === 'ok' ? '配置校验通过' : '配置校验未通过');
			var lines = [ E('div', {}, parts.map(function (p, i) { return [ i ? ' · ' : '', p ]; }).reduce(function (a, b) { return a.concat(b); }, [])) ];
			lines.push(E('div', { 'class': 'cbi-value-description' },
				'API ' + (st.api || '-') + (st.dashboard ? '，官方面板已启用' : '')));
			if (st.api_port_busy)
				lines.push(E('div', { 'style': 'color:#c60' }, '⚠ API 端口被占用，请到「面板」页改用其它端口'));
			return E('div', {}, lines);
		}

		m = new form.Map('isongwrt', 'isongwrt',
			'sing-box 内核管理与配置面板。');

		s = m.section(form.TableSection, 'status', '状态');
		s.anonymous = true;

		o = s.option(form.DummyValue, '_status', '当前状态');
		o.cfgvalue = function () { return statusLine(); };

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
