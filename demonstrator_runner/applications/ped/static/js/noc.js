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

const gridSize = 25;
const nodeSize = 6;
const nodeOffset = 6;
const routerSize = 10;
const arrowHead = 2;
const arrowHeadTDM = 1;
const chartHistory = 60;
const rgbBE = {r: 227, g: 114, b: 34}; // TUM orange (Pantone 158)
const rgbTDM = {r: 0, g: 101, b: 189}; // TUM blue (Pantone 300 C)
const maxScaledUtil = 1.5;
const utilfade = 0.1;

class Noc {
	constructor(view, xdim, ydim, updateTime, utilFactor, utilPercent, nodeTypes) {
		this.view = view;
		this.xdim = xdim;
		this.ydim = ydim;
		this.utilPercent = utilPercent;
		this.labelString = utilPercent ? '[%]' : '[cycles]'
		this.totalLinks = xdim * ydim * 8 - 2 * xdim - 2 * ydim;
		this.updateTime = updateTime;
		this.utilFactorBE = utilFactor.be;
		this.utilFactorTDM = utilFactor.tdm;
		this.nodeTypes = nodeTypes;
		this.colorCoded = true;

		var left = nodeOffset + nodeSize + 2;

		this.view.attr("viewBox", "-" + left + " -" + left + " " + ((this.xdim-1)*gridSize + left + routerSize + 2) + " " + ((this.ydim-1)*gridSize + left + routerSize + 2));
		for(var y=0; y<this.ydim; y++) {
			for(var x=0; x<this.xdim; x++) {
				this.createNode(x,y);
				if(x+1 < this.xdim) {
					this.createLink(x, y, x+1, y);
					this.createLink(x+1, y, x, y);
				}
				if(y+1 < this.ydim) {
					this.createLink(x, y, x, y+1);
					this.createLink(x, y+1, x, y);
				}
			}
		}

		this.routers = this.view.find(".router");
		this.links = this.view.find(".link");
		this.nodes = this.view.find(".node");
		this.nodesIO = this.view.find(".nodeIO");
		this.nodesLC = this.view.find(".nodeLC");
		this.nodesHC = this.view.find(".nodeHC");
		this.nodelinks = this.view.find(".nodelink");
		this.infoTabs = jQuery("[id^=tab-]");
		this.title = jQuery('#title');

		// Keep track of all IDs of shown TDM connections
		this.tdm_connections_shown = [];

		Chart.defaults.global.elements.point.radius = 0;
		this.chartConfigBE = {
			type: 'line',
			data: {
				labels: [],
				datasets: [{
					label: 'Best Effort',
					backgroundColor: '#e37222',
					borderColor: '#e37222',
					borderWidth: 1,
					fill: false,
					data: []
				}]
			},
			options: {
				scales: {
					xAxes: [{
						ticks: {
							beginAtZero: false,
							autoSkip: false,
							stepSize: 10*(1000/this.updateTime),
						},
						display: true,
						scaleLabel: {
							display: true,
							labelString: 'Time [s]',
							padding: 0
						}
					}],
					yAxes: [{
						ticks: {
							beginAtZero: true
						},
						display: true,
						scaleLabel: {
							display: true,
							labelString: 'Utilization ' + this.labelString,
							padding: 2
						}
				    }]
				},
				tooltips: {enabled: false},
				hover: {mode: null}
			}
		};
		for(var i=chartHistory*(1000/this.updateTime); i>=0; i--) {
			if (i % ((1000/this.updateTime) * 5) == 0) {
				this.chartConfigBE.data.labels.push((-i)/(1000/this.updateTime));
			} else {
				this.chartConfigBE.data.labels.push("");
			}
		}
		this.chartConfigTDM = {
			type: 'line',
			data: {
				labels: [],
				datasets: [{
					label: 'TDM',
					backgroundColor: '#0065bd',
					borderColor: '#0065bd',
					borderWidth: 1,
					fill: false,
					data: []
				}]
			},
			options: {
				scales: {
					xAxes: [{
						ticks: {
							beginAtZero: false,
							autoSkip: false,
							stepSize: 10*(1000/this.updateTime),
						},
						display: true,
						scaleLabel: {
							display: true,
							labelString: 'Time [s]',
							padding: 0
						}
					}],
					yAxes: [{
						ticks: {
							beginAtZero: true
						},
						display: true,
						scaleLabel: {
							display: true,
							labelString: 'Utilization ' + this.labelString,
							padding: 2
						}
				    }]
				},
				tooltips: {enabled: false},
				hover: {mode: null}
			}
		};
		for(var i=chartHistory*(1000/this.updateTime); i>=0; i--) {
			if (i % ((1000/this.updateTime) * 5) == 0) {
				this.chartConfigTDM.data.labels.push((-i)/(1000/this.updateTime));
			} else {
				this.chartConfigTDM.data.labels.push("");
			}
		}
		this.chartBE = this.chartBE = new Chart(document.getElementById('chartBE').getContext('2d'), this.chartConfigBE);
		this.chartTDM = this.chartTDM = new Chart(document.getElementById('chartTDM').getContext('2d'), this.chartConfigTDM);

		this.showInfo(0);
	}

	createNode(x, y) {
		var circ = document.createElementNS("http://www.w3.org/2000/svg", "circle");
		circ.setAttribute("cx", x*gridSize-nodeOffset-nodeSize/2);
		circ.setAttribute("cy", y*gridSize-nodeOffset-nodeSize/2);
		circ.setAttribute("r", nodeSize/2);
		// Different node types
		var type = this.nodeTypes[y * this.xdim + x];
		switch(type) {
		case "I/O":
			circ.setAttribute("class", "nodeIO");
			break;
		case "LCT":
			circ.setAttribute("class", "nodeLC");
			break;
		case "HCT":
			circ.setAttribute("class", "nodeHC");
			break;
		default:
			circ.setAttribute("class", "node");
		}
		circ.setAttribute("id", "node-" + x + "-" + y);
		circ.setAttribute("onclick", "nocInfo.onNodeSelected(" + x + "," + y + ")");
		this.view.append(circ);

		var rect = document.createElementNS("http://www.w3.org/2000/svg", "rect");
		rect.setAttribute("x", x*gridSize);
		rect.setAttribute("y", y*gridSize);
		rect.setAttribute("width", routerSize);
		rect.setAttribute("height", routerSize);
		rect.setAttribute("rx", 1);
		rect.setAttribute("ry", 1);
		rect.setAttribute("class", "router");
		rect.setAttribute("id", "router-" + x + "-" + y);
		rect.setAttribute("onclick", "nocInfo.onRouterSelected(" + x + "," + y + ")");
		this.view.append(rect);

		for(var i=0; i<4; ++i) {
			this.createNodeLink(x,y,i);
		}
	}

	createLink(x1, y1, x2, y2) {
		var cls = "link";
		var id = "link-" + x1 + "-" + y1 + "-" + x2 + "-" + y2;
		var onclick = "nocInfo.onLinkSelected(" + x1 + "," + y1 + "," + x2 + "," + y2 + ")";
		var uoffset = 0.1;
		if(x2 > x1) {
			this.drawArrow(x1*gridSize+routerSize+uoffset, y1*gridSize+2*routerSize/3, x2*gridSize+uoffset, y2*gridSize+2*routerSize/3, cls, id, onclick);
		} else if(x2 < x1) {
			this.drawArrow(x1*gridSize-uoffset, y1*gridSize+routerSize/3, x2*gridSize+routerSize-uoffset, y2*gridSize+routerSize/3, cls, id, onclick);
		} else if(y2 > y1) {
			this.drawArrow(x1*gridSize+routerSize/3, y1*gridSize+routerSize+uoffset, x2*gridSize+routerSize/3, y2*gridSize+uoffset, cls, id, onclick);
		} else if(y2 < y1) {
			this.drawArrow(x1*gridSize+2*routerSize/3, y1*gridSize-uoffset, x2*gridSize+2*routerSize/3, y2*gridSize+routerSize-uoffset, cls, id, onclick);
		}
	}

	createNodeLink(x, y, i) {
		var x1 = x*gridSize-0.2+(1.5-(i%2==0?i+1:i-1))*nodeSize*0.23;
		var y1 = y*gridSize-0.2-(1.5-(i%2==0?i+1:i-1))*nodeSize*0.23;
		var x2 = x*gridSize-0.4+(1.5-(i%2==0?i+1:i-1))*nodeSize*0.23 - nodeOffset;
		var y2 = y*gridSize-0.4-(1.5-(i%2==0?i+1:i-1))*nodeSize*0.23 - nodeOffset;
		var cls = "nodelink";
		var id = "nodelink-" + x + "-" + y + "-" + i;
		var onclick = "nocInfo.onNodeLinkSelected(" + x + "," + y + "," + i + ")";
		if(i<2) {
			this.drawArrow(x1,y1,x2,y2,cls,id,onclick);
		} else {
			this.drawArrow(x2,y2,x1,y1,cls,id,onclick);
		}
	}

	drawArrow(x1, y1, x2, y2, cls, id, onclick) {
		var line = document.createElementNS("http://www.w3.org/2000/svg", "line");
		var angle = Math.atan2(y2-y1, x2-x1);
		line.setAttribute("x1", x1);
		line.setAttribute("y1", y1);
		line.setAttribute("x2", x2 - Math.cos(angle)*arrowHead * 1.05);
		line.setAttribute("y2", y2 - Math.sin(angle)*arrowHead * 1.05);
		line.setAttribute("class", cls);
		line.setAttribute("id", id);
		this.view.append(line);

		line = document.createElementNS("http://www.w3.org/2000/svg", "line");
		line.setAttribute("x1", x1);
		line.setAttribute("y1", y1);
		line.setAttribute("x2", x2);
		line.setAttribute("y2", y2);
		line.setAttribute("class", "linkclick");
		line.setAttribute("onclick", onclick);
		this.view.append(line);
	}

	createTDMchannelSegment(x1, y1, x2, y2, colorclass) {
		var id = "TDMchannelSegment-" + x1 + "-" + y1 + "-" + x2 + "-" + y2;
		if(this.view.find("#" + id).length == 0) {
			var line = document.createElementNS("http://www.w3.org/2000/svg", "line");
			var angle = Math.atan2(y2-y1, x2-x1);
			line.setAttribute("x1", x1*gridSize+routerSize/2);
			line.setAttribute("y1", y1*gridSize+routerSize/2);
			line.setAttribute("x2", x2*gridSize+routerSize/2 - Math.cos(angle)*arrowHeadTDM);
			line.setAttribute("y2", y2*gridSize+routerSize/2 - Math.sin(angle)*arrowHeadTDM);
			line.setAttribute("class", colorclass);
			line.setAttribute("id", id);
			this.view.append(line);
			this.tdm_connections_shown.push(id);
		}
	}

	createTDMchannelNode(x, y, out, colorclass) {
		var id = "TDMnodeChannel-" + x + "-" + y + (out ? "-out" : "-in");
		if(this.view.find("#" + id).length == 0) {
			var line = document.createElementNS("http://www.w3.org/2000/svg", "line");
			var xnode = x*gridSize-nodeOffset-nodeSize/2;
			var ynode = y*gridSize-nodeOffset-nodeSize/2;
			var xrouter = x*gridSize+routerSize/2;
			var yrouter = y*gridSize+routerSize/2;
			var x1 = out ? xnode : xrouter;
			var y1 = out ? ynode : yrouter;
			var x2 = out ? xrouter : xnode;
			var y2 = out ? yrouter : ynode;
			var angle = Math.atan2(y2-y1, x2-x1);
			line.setAttribute("x1", x1);
			line.setAttribute("y1", y1);
			line.setAttribute("x2", x2 - Math.cos(angle)*arrowHeadTDM);
			line.setAttribute("y2", y2 - Math.sin(angle)*arrowHeadTDM);
			line.setAttribute("class", colorclass);
			line.setAttribute("id", id);
			this.view.append(line);
			this.tdm_connections_shown.push(id);
		}
	}

	createLogicalTDMconnection(x1, y1, x2, y2, colorclass) {
		var id = "TDMlogicalConnection-" + x1 + "-" + y1 + "-" + x2 + "-" + y2;
		if(this.view.find("#" + id).length == 0) {
			var line = document.createElementNS("http://www.w3.org/2000/svg", "line");
			var angle = Math.atan2(y2-y1, x2-x1);
			line.setAttribute("x1", x1*gridSize-nodeOffset-nodeSize/2 + Math.cos(angle)*arrowHeadTDM);
			line.setAttribute("y1", y1*gridSize-nodeOffset-nodeSize/2 + Math.sin(angle)*arrowHeadTDM);
			line.setAttribute("x2", x2*gridSize-nodeOffset-nodeSize/2 - Math.cos(angle)*arrowHeadTDM);
			line.setAttribute("y2", y2*gridSize-nodeOffset-nodeSize/2 - Math.sin(angle)*arrowHeadTDM);
			line.setAttribute("class", colorclass);
			line.setAttribute("id", id);
			this.view.append(line);
			this.tdm_connections_shown.push(id);
		}
	}

	clearTDMconnectionsShown() {
		for(var i = 0; i < this.tdm_connections_shown.length; i++) {
			this.view.find("#" + this.tdm_connections_shown[i]).remove();
		}
		this.tdm_connections_shown = [];
	}

	calculateColorUniform(valBE, valTDM, level) {
		if(level == 0) {
			var factor = this.utilFactorBE > this.utilFactorTDM ? this.utilFactorBE : this.utilFactorTDM;
			var val = (valBE + valTDM) / factor;
		}
		else if(level == 1)
			var val = valTDM / this.utilFactorTDM;
		else if(level == 2)
			var val = valBE / this.utilFactorBE;
		else
			var val = 0;
		if(val < 0) val = 0;
		if(val > 1) val = 1;
		if(val < 0.5) {
			return ("rgb(" + 100*(2*val) + "%,100%,0%)");
		} else  {
			return ("rgb(100%," + 100*(2-2*val) + "%,0%)");
		}
	}

	calculateColorCoded(valBE, valTDM, level) {
		if(level == 1)
			valBE = 0;
		if(level == 2)
			valTDM = 0;
		if(valBE > 1) valBE = 1;
		if(valTDM > 1) valTDM = 1;
		var r = 255;
		var g = 255;
		var b = 255;
		if(valTDM > valBE) {
			if(valTDM < 0.1) valTDM = 0.1 // min. color value
			r -= (255 - rgbTDM['r']) * valTDM;
			g -= (255 - rgbTDM['g']) * valTDM;
			b -= (255 - rgbTDM['b']) * valTDM;
		}
		else if(valBE >= valTDM && valBE != 0) {
			if(valBE < 0.1) valBE = 0.1 // min. color value
			r -= (255 - rgbBE['r']) * valBE;
			g -= (255 - rgbBE['g']) * valBE;
			b -= (255 - rgbBE['b']) * valBE;
		}
		return ("rgb(" + r + "," + g + "," + b + ")");
	}

	clearSelection() {
		this.routers.removeClass("selected");
		this.links.removeClass("selected");
		this.nodes.removeClass("selected");
		this.nodesIO.removeClass("selected");
		this.nodesLC.removeClass("selected");
		this.nodesHC.removeClass("selected");
		this.nodelinks.removeClass("selected");
		this.routers.removeClass("hideInfo");
		this.links.removeClass("hideInfo");
		this.nodes.removeClass("hideInfo");
		this.nodelinks.removeClass("hideInfo");
	}

	onRouterSelected(x, y) {
		var selectedrouter = this.view.find("#router-" + x + "-" + y);
		var success = false;
		if(selectedrouter.hasClass("available")) {
			this.routers.removeClass("available")
			selectedrouter.addClass("selected");
			success = true;
			// check if neighboring routers are available
			if(x > 0 && !this.view.find("#router-" + (x-1) + "-" + y).hasClass("selected")) {
				this.view.find("#router-" + (x-1) + "-" + y).addClass("available");
			}
			if(x < this.xdim-1 && !this.view.find("#router-" + (x+1) + "-" + y).hasClass("selected")) {
				this.view.find("#router-" + (x+1) + "-" + y).addClass("available");
			}
			if(y > 0 && !this.view.find("#router-" + x + "-" + (y-1)).hasClass("selected")) {
				this.view.find("#router-" + x + "-" + (y-1)).addClass("available");
			}
			if(y < this.ydim-1 && !this.view.find("#router-" + x + "-" + (y+1)).hasClass("selected")) {
				this.view.find("#router-" + x + "-" + (y+1)).addClass("available");
			}
		}
		return success;
	}

	onLinkSelected(x1, y1, x2, y2) {
		this.clearSelection();
		this.view.find("#link-" + x1 + "-" + y1 + "-" + x2 + "-" + y2).addClass("selected");
	}

	onNodeSelected(x, y) {
		this.clearSelection();
		this.view.find("#node-" + x + "-" + y).addClass("selected");
	}

	onNodeLinkSelected(x, y, i) {
		this.clearSelection();
		this.view.find("#nodelink-" + x + "-" + y + "-" + i).addClass("selected");
	}

	setLinkColor(x1, y1, x2, y2, linkInfo, level) {
		var line = this.view.find("#link-"+x1+"-"+y1+"-"+x2+"-"+y2);
		this.setLineColor(line, linkInfo, level);
	}
	
	setNodeLinkColor(x, y, i, linkInfo, level) {
		var line = this.view.find("#nodelink-"+x+"-"+y+"-"+i);
		this.setLineColor(line, linkInfo, level);
	}

	setLineColor(line, linkInfo, level) {
		//if(linkInfo.error) {		// show link as faulty (dashed red link) only when fault has been detected
		if(linkInfo.injectError) {	// show link as faulty (dashed red link) when fault has been injected
			line.attr("style", "stroke:#ff0000");
			line.attr("stroke-dasharray", "1,1");
		} else {
			var valBEscaled = linkInfo.utilization.be.slice(-1)[0] / this.utilFactorBE;
			var valTDMscaled = linkInfo.utilization.tdm.slice(-1)[0] / this.utilFactorTDM;
			if(valBEscaled < 0) valBEscaled = 0;
			if(valBEscaled > maxScaledUtil) valBEscaled = maxScaledUtil;
			if(valBEscaled > linkInfo.utilization.BELastScaled)
				linkInfo.utilization.BELastScaled = valBEscaled;
			else
				linkInfo.utilization.BELastScaled = linkInfo.utilization.BELastScaled > utilfade ? linkInfo.utilization.BELastScaled - utilfade : 0;
			if(valTDMscaled < 0) valTDMscaled = 0;
			if(valTDMscaled > maxScaledUtil) valTDMscaled = maxScaledUtil;
			if(valTDMscaled > linkInfo.utilization.TDMLastScaled)
				linkInfo.utilization.TDMLastScaled = valTDMscaled;
			else
				linkInfo.utilization.TDMLastScaled = linkInfo.utilization.TDMLastScaled > utilfade ? linkInfo.utilization.TDMLastScaled - utilfade : 0;
			if(this.colorCoded)
				var color = this.calculateColorCoded(linkInfo.utilization.BELastScaled,linkInfo.utilization.TDMLastScaled,level);
			else
				var color = this.calculateColorUniform(linkInfo.utilization.BELastScaled,linkInfo.utilization.TDMLastScaled,level);
			line.attr("style", "stroke:" + color);
			line.attr("stroke-dasharray", "");
		}
	}

	showInfo(level) {
		this.infoLevel = level;
		this.clearSelection();

		this.infoTabs.removeClass("selected");
		jQuery("#tab-" + level).addClass("selected");
	}

	setChartData(data) {
		this.chartConfigBE.data.datasets[0].data = data.be;
		this.chartConfigTDM.data.datasets[0].data = data.tdm;
		this.chartBE.update();
		this.chartTDM.update();
	}

	setTitle(text) {
		this.title.text(text);
	}
}

class NodeInfo {
	constructor(xdim, ydim, type, nodeInit) {
		this.xdim = xdim;
		this.ydim = ydim;
		this.type = type;
		this.info = nodeInit.info;
		this.select = 'nodeTabSelect-0';
		this.tab = 'nodeTabContent-0';
		this.stats = nodeInit.stats;
		this.tdmEP = nodeInit.num_tdm_ep;
		if(type == "LCT") {
			this.beEnabled = nodeInit.be_config.lct_dest;
			this.updateNodeConfBE(nodeInit.be_config);
		}
		// Indices of outgoing/incoming TDM channels
		this.tdm_channels = [];
	}

	updateNodeConfBE(nodeConf) {
		this.minBurst = nodeConf.min_burst;
		this.maxBurst = nodeConf.max_burst;
		this.minDelay = nodeConf.min_delay;
		this.maxDelay = nodeConf.max_delay;
	}
}

class NocInfo {
	constructor(noc, generalInfo, nodeInit) {//, paths, connections) {
		this.noc = noc;
		this.link = [];
		this.nodeLink = [];
		this.node = [];
		this.level = 0;
		this.selection = null;
		this.pathsetupactive = false;
		this.setupchid = null;
		this.setuppathidx = null;
		this.setuppath = [];
		this.setupdest = {};
		this.set_clr_btn = null;
		this.utilization = {be: [], tdm: []};
		this.clearChartData(this.utilization);
		this.generalInfo = generalInfo;
		//this.swToggleColors = jQuery('#swToggleColors');
		this.noc.colorCoded = true; //this.swToggleColors[0].checked;
		this.divInfoText = jQuery('#info');
		this.btnToggleError = jQuery('#btnToggleError');

		for(var y=0; y < this.noc.ydim; y++) {
			for(var x=0; x < this.noc.xdim; x++) {
				this.createNode(x, y, nodeInit[y * this.noc.xdim + x]);
				if(x+1 < this.noc.xdim) {
					this.createLink(x, y, x+1, y);
					this.createLink(x+1, y, x, y);
				}
				if(y+1 < this.noc.ydim) {
					this.createLink(x, y, x, y+1);
					this.createLink(x, y+1, x, y);
				}
			}
		}

		// Prepare arrays for TDM paths and connections
		this.paths = {};
		this.channels = {};

		this.showInfo(0);
		setInterval(this.updateInfo, 500);
	}

	createNode(x, y, nodeInit) {
		if(!this.node[x]) this.node[x] = [];
		this.node[x][y] = new NodeInfo(this.noc.xdim, this.noc.ydim, this.noc.nodeTypes[y * this.noc.xdim + x], nodeInit);
		if(!this.nodeLink[x]) this.nodeLink[x] = [];
		this.nodeLink[x][y] = [];
		for(var i=0; i<4; ++i) {
			this.nodeLink[x][y][i] = {utilization: {be: [], tdm: [], BELastScaled: 0, TDMLastScaled: 0}, error: false, injectError: false, info: ''};
			this.clearChartData(this.nodeLink[x][y][i].utilization);
		}
	}

	createLink(x1, y1, x2, y2) {
		if(!this.link[x1]) this.link[x1] = [];
		if(!this.link[x1][y1]) this.link[x1][y1] = [];
		if(!this.link[x1][y1][x2]) this.link[x1][y1][x2] = [];
		this.link[x1][y1][x2][y2] = {utilization: {be: [], tdm: [], BELastScaled: 0, TDMLastScaled: 0}, error: false, injectError: false, info: ''};
		this.clearChartData(this.link[x1][y1][x2][y2].utilization);
	}

	showInfo(level) {
		this.cancelPathSetup();
		this.noc.showInfo(level);
		this.level = level;
		this.selection = null;
		this.noc.setTitle('Global')
		this.updateUi();
		this.selectInfo();
	}

	onRouterSelected(x, y) {
		if(this.noc.onRouterSelected(x,y)) {
			this.setuppath.push([x, y]);
			if(x == this.setupdest['dest_x'] && y == this.setupdest['dest_y']) {
				socket.emit('setup_path', {chid: this.setupchid, path_idx: this.setuppathidx, path: this.setuppath});
				this.cancelPathSetup();
			}
			this.updateUi();
		}
	}

	onLinkSelected(x1, y1, x2, y2) {
		this.cancelPathSetup();
		this.noc.onLinkSelected(x1,y1,x2,y2);
		this.selection = {type: 'link', x1: x1, y1: y1, x2: x2, y2: y2};
		this.noc.setTitle('Link (' + x1 + ',' + y1 + ') → (' + x2 + ',' + y2 + ')');
		this.updateUi();
		this.selectInfo();
	}

	onNodeSelected(x, y) {
		this.cancelPathSetup();
		this.noc.onNodeSelected(x,y);
		this.selection = {type: 'node', x: x, y: y};
		this.noc.setTitle('Global');
		this.btnToggleError.hide();
		this.updateUi();
		this.selectInfo();
	}

	onNodeLinkSelected(x, y, i) {
		this.cancelPathSetup();
		this.noc.onNodeLinkSelected(x, y, i);
		this.selection = {type: 'nodeLink', x: x, y: y, i: i};
		this.noc.setTitle('Local ' + ((i<2) ? ('in ' + i) : ('out ' + (i-2))) + ' @(' + x + ',' + y + ')');
		this.updateUi();
		this.selectInfo();
	}
	
	updateUi() {
		this.noc.clearTDMconnectionsShown();
		if(!this.selection) {
			this.noc.setChartData(this.utilization);
			this.btnToggleError.hide();
		} else {
			//console.log(this.selection.type);
			if(this.selection.type == 'link') {
				this.noc.setChartData(this.link[this.selection.x1][this.selection.y1][this.selection.x2][this.selection.y2].utilization);
				this.btnToggleError.show();
				if(this.btnToggleError.hasClass('btnPressed') && !this.link[this.selection.x1][this.selection.y1][this.selection.x2][this.selection.y2].injectError) {
					this.btnToggleError.removeClass('btnPressed');
					this.btnToggleError.text('Inject fault');
				} else if(!this.btnToggleError.hasClass('btnPressed') && this.link[this.selection.x1][this.selection.y1][this.selection.x2][this.selection.y2].injectError) {
					this.btnToggleError.addClass('btnPressed');
					this.btnToggleError.text('Clear fault');
				}
				for(var i = 0; i < this.link[this.selection.x1][this.selection.y1][this.selection.x2][this.selection.y2].pid.length; i++) {
					this.drawTDMpath(this.link[this.selection.x1][this.selection.y1][this.selection.x2][this.selection.y2].pid[i], "tdmchannel");
				}
			} else if(this.selection.type == 'nodeLink') {
				this.noc.setChartData(this.nodeLink[this.selection.x][this.selection.y][this.selection.i].utilization);
				this.btnToggleError.show();
				if(this.btnToggleError.hasClass('btnPressed') && !this.nodeLink[this.selection.x][this.selection.y][this.selection.i].injectError) {
					this.btnToggleError.removeClass('btnPressed');
					this.btnToggleError.text('Inject fault');
				} else if(!this.btnToggleError.hasClass('btnPressed') && this.nodeLink[this.selection.x][this.selection.y][this.selection.i].injectError) {
					this.btnToggleError.addClass('btnPressed');
					this.btnToggleError.text('Clear fault');
				}
				for(var i = 0; i < this.nodeLink[this.selection.x][this.selection.y][this.selection.i].pid.length; i++) {
					this.drawTDMpath(this.nodeLink[this.selection.x][this.selection.y][this.selection.i].pid[i], "tdmchannel");
				}
			} else if(this.selection.type == 'node') {
				this.noc.setChartData(this.utilization);
				if(!this.setuppathactive) {
					for(var i = 0; i < this.node[this.selection.x][this.selection.y].tdm_channels.length; i++) {
						this.drawTDMconnection(this.node[this.selection.x][this.selection.y].tdm_channels[i], "tdmconnection");
					}
				}
				else {
					// The order of these matters for overlapping
					this.drawTDMsetuppath();
					this.drawTDMchannel(this.setupchid, "tdmchannel");
					this.drawTDMconnection(this.setupchid, "tdmconnectionsetup");
				}
			} else {
				this.noc.setChartData(this.utilization);
				this.btnToggleError.hide();
			}
		}
		for(var y=0; y<this.noc.ydim; y++) {
			for(var x=0; x<this.noc.xdim; x++) {
				for(var i=0; i<4; ++i) {
					this.noc.setNodeLinkColor(x,y,i,this.nodeLink[x][y][i],this.level);
				}
				if(x+1 < this.noc.xdim) {
					this.noc.setLinkColor(x,y,x+1,y,this.link[x][y][x+1][y],this.level);
					this.noc.setLinkColor(x+1,y,x,y,this.link[x+1][y][x][y],this.level);
				}
				if(y+1 < this.noc.ydim) {
					this.noc.setLinkColor(x,y,x,y+1,this.link[x][y][x][y+1],this.level);
					this.noc.setLinkColor(x,y+1,x,y,this.link[x][y+1][x][y],this.level);
				}
			}
		}
	}

	updateInfo() {
		if(nocInfo.selection && nocInfo.selection.type == 'node') {
			var node = nocInfo.node[nocInfo.selection.x][nocInfo.selection.y];
			switch(node.type) {
			case "I/O":
			case "HCT":
				if(node.select == 'nodeTabSelect-0') {
					var showFaultyBE = node.type == "I/O" ? true : false;
					nocInfo.updateTDMstats(node, showFaultyBE);
				}
				else if(node.select == 'nodeTabSelect-1')
					nocInfo.updateTDMconfig(node);
				break;
			case "LCT":
				if(node.select == 'nodeTabSelect-0')
					nocInfo.updateBEstats(node);
				else if(node.select == 'nodeTabSelect-1')
					nocInfo.updateBEconfig(node);
				break;
			default:;
			}
		}
	}

	drawTDMpath(pid, colorclass) {
		if(pid != null) {
			var src_x = this.paths[pid]['path_x'][0];
			var src_y = this.paths[pid]['path_y'][0];
			this.noc.createTDMchannelNode(src_x, src_y, true, colorclass);
			for(var i = 0; i < this.paths[pid]['path_x'].length - 1; i++) {
				this.noc.createTDMchannelSegment(
						this.paths[pid]['path_x'][i],
						this.paths[pid]['path_y'][i],
						this.paths[pid]['path_x'][i+1],
						this.paths[pid]['path_y'][i+1],
						colorclass);
			}
			var dest_x = this.paths[pid]['path_x'][this.paths[pid]['path_x'].length - 1];
			var dest_y = this.paths[pid]['path_y'][this.paths[pid]['path_y'].length - 1];
			this.noc.createTDMchannelNode(dest_x, dest_y, false, colorclass);
		}
	}

	drawTDMsetuppath() {
		if(this.setuppathactive && this.setuppath.length > 0) {
			var src_x = this.channels[this.setupchid]['src_x'];
			var src_y = this.channels[this.setupchid]['src_y'];
			this.noc.createTDMchannelNode(src_x, src_y, true, "tdmchannelsetup");
			for(var i = 0; i < this.setuppath.length - 1; i++) {
				this.noc.createTDMchannelSegment(
						this.setuppath[i][0],
						this.setuppath[i][1],
						this.setuppath[i+1][0],
						this.setuppath[i+1][1],
						"tdmchannelsetup");
			}
		}
	}

	drawTDMconnection(chid, colorclass) {
		this.noc.createLogicalTDMconnection(
				this.channels[chid]['src_x'],
				this.channels[chid]['src_y'],
				this.channels[chid]['dest_x'],
				this.channels[chid]['dest_y'],
				colorclass);
		//this.drawTDMchannel(chid, colorclass);
	}

	drawTDMchannel(chid, colorclass) {
		for(var i = 0; i < this.channels[chid]['pids'].length; i++) {
			this.drawTDMpath(this.channels[chid]['pids'][i], colorclass);
		}
	}

	displayTDMconfig(ep, chid) {
		if(chid >= 0) {
			// Display destination
			var destID = this.noc.xdim * this.channels[chid]['dest_y'] + this.channels[chid]['dest_x'];
			jQuery('#channel_dest_' + ep).text(destID);
			// Display paths
			for(var i = 0; i < this.channels[chid]['pids'].length; i++) {
				var pid = this.channels[chid]['pids'][i];
				var set_clr_btn = jQuery('#btn_set_clr_ch_' + ep + '_path_' + i);
				set_clr_btn.show();
				if(pid != null) {
					// path set up
					var pathstr = this.paths[pid]['path'][0]; // add first hop (current node)
					for(var j = 1; j < this.paths[pid]['path'].length; j++) {
						pathstr += ' \u2192 ' + this.paths[pid]['path'][j]; // print path with right arrows between hops
					}
					jQuery('#path_' + i + '_channel_' + ep).text(pathstr);
					set_clr_btn.text('Clear');
				}
				else {
					// no path set up
					if(!this.setuppathactive || !set_clr_btn.hasClass("btnPressed")) {
						set_clr_btn.removeClass('btnPressed');
						set_clr_btn.text('Configure');
					}
				}
			}
		}
		else {
			// hide buttons
			for(var i = 0; i < 2; i++) {
				jQuery('#btn_set_clr_ch_' + ep + '_path_' + i).hide();
			}
		}
	}

	updateTDMstats(node, showFaultyBE) {
		for(var x = 0; x < node.tdmEP; x++) {
			jQuery('#sent_ep_' + x).text(node.stats.tdm_sent[x]);
			jQuery('#rcvd_ep_' + x).text(node.stats.tdm_rcvd[x]);
		}
		if (showFaultyBE) {
			jQuery('#faulty_be').text(node.stats.be_faults);
		}
	}

	updateBEstats(node) {
		for(var n = 0; n < node.xdim * node.ydim; n++) {
			jQuery('#sent_rec_node_' + n).html(node.stats.be_sent[n] + ' /<br>' + node.stats.be_rcvd[n]);
		}
		jQuery('#faulty_be').text(node.stats.be_faults);
	}

	updateTDMconfig(node) {
		for(var ep = 0; ep < node.tdmEP; ep++) {
			var chid = -1;
			for(var i = 0; i < node.tdm_channels.length; i++) {
				var chid_tmp = node.tdm_channels[i];
				if(this.channels[chid_tmp]['src_x'] == this.selection.x && this.channels[chid_tmp]['src_y'] == this.selection.y &&
					this.channels[chid_tmp]['ep_src'] == ep) {
					chid = chid_tmp;
					break;
				}
			}
			this.displayTDMconfig(ep, chid);
		}
	}

	updateBEconfig(node) {
		// enable/disable nodes
		for(var n = 0; n < node.xdim * node.ydim; n++) {
			if(node.beEnabled[n].checked)
				jQuery('#swNode' + n).prop("checked", true);
		}
		// update current burst and delay
		var burst = node.minBurst == node.maxBurst ? node.maxBurst : node.minBurst + ' - ' + node.maxBurst;
		jQuery('#burstLen').text(burst);
		var delay = node.minDelay == node.maxDelay ? node.maxDelay : node.minDelay + ' - ' + node.maxDelay;
		jQuery('#loopIter').text(delay);
	}

	selectInfo() {
		if(!this.selection) {
			this.divInfoText.html(this.generalInfo);
		} else {
			if(this.selection.type == 'link') {
				this.divInfoText.html(this.link[this.selection.x1][this.selection.y1][this.selection.x2][this.selection.y2].info);
				this.linkFaultInfo(this.link[this.selection.x1][this.selection.y1][this.selection.x2][this.selection.y2]);
			} else if(this.selection.type == 'nodeLink') {
				this.divInfoText.html(this.nodeLink[this.selection.x][this.selection.y][this.selection.i].info);
				this.linkFaultInfo(this.nodeLink[this.selection.x][this.selection.y][this.selection.i]);
			} else if(this.selection.type == 'node') {
				this.divInfoText.html(this.node[this.selection.x][this.selection.y].info);
				this.selectNodeTab(this.node[this.selection.x][this.selection.y].select, this.node[this.selection.x][this.selection.y].tab);
				this.updateInfo();
			} else {
				this.divInfoText.html(this.generalInfo);
			}
		}
	}

	linkFaultInfo(link) {
		var fault_info = jQuery('#link_fault');
		var txt = '';
		if(link.error) {
			txt = 'Fault detected';
		} else if(link.injectError) {
			txt = 'Fault injected (undetected)';
		}
		fault_info.text(txt);
	}

	clearChartData(data) {
		data.be = [];
		data.tdm = [];
		for(var i = 0; i <= chartHistory * (1000/this.noc.updateTime); i++) {
			data.be.push(null);
			data.tdm.push(null);
		}
	}

	updateUtilData(utilData) {
		var beTotal = 0;
		var tdmTotal = 0;
		for (var y = 0; y < this.noc.ydim; y++) {
			for (var x = 0; x < this.noc.xdim; x++) {
				var i = y * this.noc.xdim + x;
				var x2 = x;
				var y2 = y;
				// Update util for up to 4 directions
				// North
				if (y > 0) {
					x2 = x;
					y2 = y - 1;
					var be = utilData.be[i][0];
					var tdm = utilData.tdm[i][0];
					this.addLinkData(x, y, x2, y2, be, tdm);
					beTotal += be;
					tdmTotal += tdm;
				}
				// East
				if (x < this.noc.xdim - 1) {
					x2 = x + 1;
					y2 = y;
					var be = utilData.be[i][1];
					var tdm = utilData.tdm[i][1];
					this.addLinkData(x, y, x2, y2, be, tdm);
					beTotal += be;
					tdmTotal += tdm;
				}
				// South
				if (y < this.noc.ydim - 1) {
					x2 = x;
					y2 = y + 1;
					var be = utilData.be[i][2];
					var tdm = utilData.tdm[i][2];
					this.addLinkData(x, y, x2, y2, be, tdm);
					beTotal += be;
					tdmTotal += tdm;
				}
				// West
				if (x > 0) {
					x2 = x - 1;
					y2 = y;
					var be = utilData.be[i][3];
					var tdm = utilData.tdm[i][3];
					this.addLinkData(x, y, x2, y2, be, tdm);
					beTotal += be;
					tdmTotal += tdm;
				}
				// Update util for node links
				for (var l = 0; l < 4; l++) {
					var be = utilData.be[i][l+4];
					var tdm = utilData.tdm[i][l+4];
					this.nodeLink[x][y][l].utilization.be.shift();
					this.nodeLink[x][y][l].utilization.be.push(be);
					this.nodeLink[x][y][l].utilization.tdm.shift();
					this.nodeLink[x][y][l].utilization.tdm.push(tdm);
					beTotal += be;
					tdmTotal += tdm;
				}
			}
		}
		if (this.noc.utilPercent) {
			beTotal /= this.noc.totalLinks;
			tdmTotal /= this.noc.totalLinks;
		}
		this.utilization.be.shift();
		this.utilization.be.push(beTotal);
		this.utilization.tdm.shift();
		this.utilization.tdm.push(tdmTotal);
		this.updateUi();
		//console.log(this.link);
		//console.log(this.nodeLink);
	}

	addLinkData(x1, y1, x2, y2, be, tdm) {
		this.link[x1][y1][x2][y2].utilization.be.shift();
		this.link[x1][y1][x2][y2].utilization.be.push(be);
		this.link[x1][y1][x2][y2].utilization.tdm.shift();
		this.link[x1][y1][x2][y2].utilization.tdm.push(tdm);
	}

	updateLinkInfo(linkInfo) {
		for (var y = 0; y < this.noc.ydim; y++) {
			for (var x = 0; x < this.noc.xdim; x++) {
				var i = y * this.noc.xdim + x;
				var x2 = x;
				var y2 = y;
				// Update info for up to 4 directions
				// North
				if (y > 0) {
					x2 = x;
					y2 = y - 1;
					this.link[x][y][x2][y2].error = linkInfo.error[i][0];
					this.link[x][y][x2][y2].injectError = linkInfo.injectError[i][0];
					this.link[x][y][x2][y2].info = linkInfo.info[i][0];
					this.link[x][y][x2][y2].pid = linkInfo.pid[i][0];
				}
				// East
				if (x < this.noc.xdim - 1) {
					x2 = x + 1;
					y2 = y;
					this.link[x][y][x2][y2].error = linkInfo.error[i][1];
					this.link[x][y][x2][y2].injectError = linkInfo.injectError[i][1];
					this.link[x][y][x2][y2].info = linkInfo.info[i][1];
					this.link[x][y][x2][y2].pid = linkInfo.pid[i][1];
				}
				// South
				if (y < this.noc.ydim - 1) {
					x2 = x;
					y2 = y + 1;
					this.link[x][y][x2][y2].error = linkInfo.error[i][2];
					this.link[x][y][x2][y2].injectError = linkInfo.injectError[i][2];
					this.link[x][y][x2][y2].info = linkInfo.info[i][2];
					this.link[x][y][x2][y2].pid = linkInfo.pid[i][2];
				}
				// West
				if (x > 0) {
					x2 = x - 1;
					y2 = y;
					this.link[x][y][x2][y2].error = linkInfo.error[i][3];
					this.link[x][y][x2][y2].injectError = linkInfo.injectError[i][3];
					this.link[x][y][x2][y2].info = linkInfo.info[i][3];
					this.link[x][y][x2][y2].pid = linkInfo.pid[i][3];
				}
				// Update util for node links
				for (var l = 0; l < 4; l++) {
					this.nodeLink[x][y][l].error = linkInfo.error[i][l+4];
					this.nodeLink[x][y][l].injectError = linkInfo.injectError[i][l+4];
					this.nodeLink[x][y][l].info = linkInfo.info[i][l+4];
					this.nodeLink[x][y][l].pid = linkInfo.pid[i][l+4];
				}
			}
		}
		this.selectInfo();
	}

	updateConnectionInfo(connectionInfo) {
		this.paths = connectionInfo.paths;
		this.channels = connectionInfo.channels;
		for(var x = 0; x < this.noc.xdim; x++) {
			for(var y = 0; y < this.noc.ydim; y++) {
				this.node[x][y].tdm_channels = connectionInfo.nodes[x][y];
			}
		}
		this.updateUi();
		this.selectInfo();
	}

	updateNodeStat(nodeStat) {
		for(var x = 0; x < this.noc.xdim; x++) {
			for(var y = 0; y < this.noc.ydim; y++) {
				this.node[x][y].stats = nodeStat[y * this.noc.xdim + x];
			}
		}
	}

	updateNodeConfBE(x, y, nodeConf) {
		this.node[x][y].updateNodeConfBE(nodeConf);
		// Update info box
		this.updateInfo();
	}

	configureTDMpath(ep, path_idx) {
		// determine chid
		var node = this.node[this.selection.x][this.selection.y];
		var chid = -1;
		for(var i = 0; i < node.tdm_channels.length; i++) {
			var chid_tmp = node.tdm_channels[i];
			if(this.channels[chid_tmp]['src_x'] == this.selection.x && this.channels[chid_tmp]['src_y'] == this.selection.y &&
				this.channels[chid_tmp]['ep_src'] == ep) {
				chid = chid_tmp;
				break;
			}
		}
		var pid = this.channels[chid]['pids'][path_idx];
		// check if clear or setup
		if(pid != null) {
			socket.emit('clr_path', {chid: chid, path_idx: path_idx});
			this.cancelPathSetup();
		}
		else {
			this.setupNewPath(node, chid, path_idx);
		}
		this.updateUi();
	}

	setupNewPath(node, chid, path_idx) {
		var set_clr_btn = jQuery("#btn_set_clr_ch_" + this.channels[chid]['ep_src'] + "_path_" + path_idx);
		// Check if either no path is being setup or not a different configure
		// has been started
		if(!this.setuppathactive || !set_clr_btn.hasClass("btnPressed")) {
			if(!set_clr_btn.hasClass("btnPressed")) {
				this.cancelPathSetup();
			}
			this.set_clr_btn = jQuery("#btn_set_clr_ch_" + this.channels[chid]['ep_src'] + "_path_" + path_idx);
			this.set_clr_btn.addClass("btnPressed");
			this.set_clr_btn.text("Cancel");
			this.noc.view.find("#router-" + this.selection.x + "-" + this.selection.y).addClass("available");
			this.setupchid = chid;
			this.setuppathidx = path_idx;
			this.setupdest = {dest_x: this.channels[chid]['dest_x'], dest_y: this.channels[chid]['dest_y']};
			this.setuppathactive = true;
		}
		else {
			this.cancelPathSetup();
		}
	}

	cancelPathSetup() {
		if(this.setuppathactive) {
			this.set_clr_btn.removeClass("btnPressed");
			this.set_clr_btn.text("Configure");
			this.set_clr_btn = null;
			this.noc.routers.removeClass("available");
			this.noc.routers.removeClass("selected");
			this.setupchid = null;
			this.setuppathidx = null;
			this.setuppath = [];
			this.setupdest = {};
			this.setuppathactive = false;
		}
	}

	displayError(msg) {
		alert(msg);
	}

	toggleErrorInjection() {
		if(this.selection) {
			var injectError = false;
			var i=0;
			var l=0;
			if(this.selection.type == 'link') {
				injectError = !this.link[this.selection.x1][this.selection.y1][this.selection.x2][this.selection.y2].injectError;
				this.link[this.selection.x1][this.selection.y1][this.selection.x2][this.selection.y2].injectError = injectError;
				i = this.noc.xdim*this.selection.y1 + this.selection.x1;
				if(this.selection.y2 < this.selection.y1) {
					l = 0;
				} else if(this.selection.y2 > this.selection.y1) {
					l = 2;
				} else if(this.selection.x2 < this.selection.x1) {
					l = 3;
				} else {
					l = 1;
				}
			} else if(this.selection.type == 'nodeLink') {
				injectError = !this.nodeLink[this.selection.x][this.selection.y][this.selection.i].injectError;
				this.nodeLink[this.selection.x][this.selection.y][this.selection.i].injectError = injectError;
				i = this.noc.xdim*this.selection.y + this.selection.x;
				l = this.selection.i + 4;
			}
			socket.emit('injectFault', {node: i, link: l, inject: injectError});
			this.updateUi();
		}
	}

	toggleColors() {
		this.noc.colorCoded = this.swToggleColors[0].checked;
		this.updateUi();
	}

	setBurst(node) {
		var terminalCommandLine = jQuery('#burstCommandLine');
		var cmd = terminalCommandLine.val();
		if(!cmd) return;
		terminalCommandLine.val('');
		socket.emit('set burst', {node: node, cmd: cmd});
	}

	setProcDelay(node) {
		var terminalCommandLine = jQuery('#procDelayCommandLine');
		var cmd = terminalCommandLine.val();
		if(!cmd) return;
		terminalCommandLine.val('');
		socket.emit('set proc delay', {node: node, cmd: cmd});
	}

	toggleDestination(src, dest) {
		var checked = jQuery('#swNode' + dest)[0].checked;
		this.node[this.selection.x][this.selection.y].beEnabled[dest].checked = checked;
		socket.emit('setLCTDest', {node: src, dest: dest, set: checked});
	}

	selectNodeTab(select, tab) {
		var i, tabcontent, tabs;

		// Set active content
		tabcontent = document.getElementsByClassName("nodetabcontent");
		for (i = 0; i < tabcontent.length; i++) {
			tabcontent[i].style.display = "none";
		}
		document.getElementById(tab).style.display = "block";

		// Set active tab
		tabs = jQuery("[id^=nodeTabSelect]");
		tabs.removeClass("selected");
		jQuery("#" + select).addClass("selected");

		// Update selected tab
		this.node[this.selection.x][this.selection.y].select = select;
		this.node[this.selection.x][this.selection.y].tab = tab;

		// Update info box
		this.updateInfo();
	}
}
