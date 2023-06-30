/* Copyright (c) 2019-2022 by the author(s)
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 *
 * =============================================================================
 *
 * Author(s):
 *   Max Koenen <max.koenen@tum.de>
 *   Dirk Gabriel
 */

var socket = null;
var noc = null;
var nocInfo = null;

jQuery(document).ready(function() {
	socket = io.connect('http://' + document.domain + ':' + location.port);
	socket.on( 'connect', function() {
		//console.log('requesting config data..');
		socket.emit( 'request', {
			req: 'init'
		});
	});
	socket.on( 'init', function(msg) {
		//console.log('received init');
		//console.log(msg);
		noc = new Noc(jQuery("#noc"), msg.x, msg.y, msg.updateTime, msg.utilFactor, msg.utilPercent, msg.nodeTypes);
		nocInfo = new NocInfo(noc, msg.generalInfo, msg.nodeInit);
		nocInfo.updateLinkInfo(msg.linkInfo);
		nocInfo.updateConnectionInfo(msg.connections);
		socket.emit( 'ready');
	});
	socket.on( 'update util', function(msg) {
		nocInfo.updateUtilData(msg);
	});
	socket.on( 'update link info', function(msg) {
		nocInfo.updateLinkInfo(msg);
	});
	socket.on( 'update node stat', function(msg) {
		nocInfo.updateNodeStat(msg);
	});
	socket.on( 'update node conf be', function(msg) {
		nocInfo.updateNodeConfBE(msg.x, msg.y, msg.nodeConf);
	});
	socket.on( 'update connections', function(msg) {
		nocInfo.updateConnectionInfo(msg);
	});
	socket.on( 'display error', function(msg) {
		nocInfo.displayError(msg);
	});
	socket.on( 'stop server', function(msg) {
		socket.emit('stop server');
	});
});
