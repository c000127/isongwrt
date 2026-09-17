'use strict';
'require view';
'require form';
'require tools.isongwrt as iso';

function btn(label, style, fn) {
	return E('button', { 'class': 'btn cbi-button cbi-button-' + style, 'click': fn }, label);
}

return view.extend({
	load: function () {
		return iso.loadUci();
	},

	render: function () {
		var m, s, o, self = this;

		function panelUrl() {
			return window.location.protocol + '//' + window.location.hostname + ':' +
				iso.get('api_port', '9090') + '/dashboard/';
		}

		m = new form.Map('isongwrt', '面板',
			'开启后内核自动下载并托管官方 sing-box-dashboard 于 /dashboard/（默认每天检查更新）。' +
			'监听 0.0.0.0，局域网可访问；访问密钥已自动生成。');

		s = m.section(form.NamedSection, 'main', 'isongwrt', 'API / 官方面板');
		s.anonymous = true;

		o = s.option(form.Flag, 'dashboard', '启用官方面板');
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.Value, 'api_port', '监听端口',
			'默认 9090 与 mihomo/nikki 的 Clash API 相同，同机部署请改（如 9095）。');
		o.datatype = 'port';
		o.default = '9090';
		o.rmempty = false;

		o = s.option(form.Value, 'api_secret', '访问密钥',
			'浏览器打开面板时填入；留空 = 保存并应用时自动生成（刷新本页可见），也可用右侧按钮重新生成。');

		o = s.option(form.Value, 'dashboard_download_url', '面板资源地址',
			'留空 = 官方 gh-pages zip；亦可手工放入工作目录的 dashboard/ 目录。');

		o = s.option(form.DummyValue, '_actions', '操作');
		o.cfgvalue = function () {
			return E('div', {}, [
				btn('生成新密钥', 'action', function () {
					return iso.busy(iso.call(['api-secret-new']), '生成新密钥…').then(function (r) {
						iso.notify(r, '已生成新密钥，保存并应用后生效');
						window.location.reload();
					});
				}),
				' ',
				E('a', { 'class': 'btn cbi-button', 'href': panelUrl(), 'target': '_blank' }, '打开面板')
			]);
		};

		s = m.section(form.NamedSection, 'main', 'isongwrt', 'Clash API（可选）');
		s.anonymous = true;

		o = s.option(form.Flag, 'clash_api', '启用 Clash API',
			'供 zashboard / metacubexd 等 Clash 协议面板使用。');
		o.default = '0';
		o.rmempty = false;

		o = s.option(form.Value, 'clash_port', 'Clash 端口');
		o.datatype = 'port';
		o.default = '9091';
		o.rmempty = false;

		o = s.option(form.Value, 'clash_secret', 'Clash 密钥',
			'留空 = 不鉴权（仅建议在本机/受信网络使用）。');

		return m.render();
	}
});
