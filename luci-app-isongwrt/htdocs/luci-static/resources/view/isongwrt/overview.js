'use strict';
'require view';
'require form';
'require dom';
'require poll';
'require ui';
'require tools.isongwrt as iso';

function row(k, v) {
	return E('tr', { 'class': 'tr' }, [
		E('td', { 'class': 'td left', 'width': '33%' }, E('strong', {}, k)),
		E('td', { 'class': 'td left' }, v)
	]);
}

function statusTable(st) {
	st = st || {};
	var rows = [
		row('运行状态', st.running
			? E('span', { 'style': 'color:green' }, '运行中 (PID ' + (st.pid || '?') + ')')
			: E('span', { 'style': 'color:red' }, '已停止')),
		row('内核版本', st.version || E('em', {}, '未安装（请到「内核管理」安装）')),
		row('激活版本', st.active || '-'),
		row('渠道 / 架构', (st.channel || '-') + ' / ' + (st.arch || '-')),
		row('内核路径', st.core_path || '-'),
		row('配置目录', (st.conf_dir || '-') + '（' + (st.conf_files || 0) + ' 个分片文件）'),
		row('配置校验', st.config_check === 'ok'
			? E('span', { 'style': 'color:green' }, '通过')
			: E('span', { 'style': 'color:red' }, '未通过（见「日志」页）')),
		row('API / 面板', (st.api || '-') + (st.dashboard ? '（官方 dashboard 已启用）' : ''))
	];
	if (st.api_port_busy)
		rows.push(row('提示', E('span', { 'style': 'color:#c60' },
			'API 端口被占用：请到「面板」页改用其它端口，否则内核无法启动')));
	return E('table', { 'class': 'table' }, rows);
}

return view.extend({
	load: function () {
		return iso.call(['status']);
	},

	render: function (status) {
		var m, s, o, self = this;

		function refreshStatus() {
			return iso.call(['status']).then(function (st) {
				self.status = st || {};
				var el = document.getElementById('iso-status');
				if (el)
					dom.content(el, statusTable(self.status));
			});
		}

		function action(args, label) {
			return iso.busy(iso.call(args), label + '…').then(function (r) {
				iso.notify(r, label + ' 完成');
				return refreshStatus();
			});
		}

		this.status = status || {};

		m = new form.Map('isongwrt', 'isongwrt 运行状态',
			'sing-box 内核管理与配置面板。设置项修改后点「保存并应用」生效；服务操作按钮立即执行。');

		/* ---- 状态（只读，5 秒自动刷新） ---- */
		s = m.section(form.TableSection, 'status', '状态');
		s.anonymous = true;

		o = s.option(form.DummyValue, '_status');
		o.cfgvalue = function () {
			return E('div', { 'id': 'iso-status' }, statusTable(self.status));
		};

		o = s.option(form.Button, 'start');
		o.inputstyle = 'apply';
		o.inputtitle = '启动';
		o.onclick = function () { return action(['service', 'start'], '启动服务'); };

		o = s.option(form.Button, 'stop');
		o.inputstyle = 'reset';
		o.inputtitle = '停止';
		o.onclick = function () { return action(['service', 'stop'], '停止服务'); };

		o = s.option(form.Button, 'restart');
		o.inputstyle = 'action';
		o.inputtitle = '重启';
		o.onclick = function () { return action(['service', 'restart'], '重启服务'); };

		/* ---- 设置（UCI，随「保存并应用」生效） ---- */
		s = m.section(form.NamedSection, 'main', 'isongwrt', '服务设置');
		s.anonymous = true;

		o = s.option(form.Flag, 'enabled', '开机自启',
			'随系统启动并自动拉起（procd）；关闭后开机不启动，可用上方按钮手动启动。');

		poll.add(refreshStatus, 5);

		return m.render();
	}
});
