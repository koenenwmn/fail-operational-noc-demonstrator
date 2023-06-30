"""
Copyright (c) 2019-2023 by the author(s)

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.

=============================================================================

Utility methods to find disjoint paths.

Author(s):
  Max Koenen <max.koenen@tum.de>

"""

def check_valid_path(x_dim, path):
    """
    Check whether or not a given path is valid.
    """
    valid = True
    i = 0
    while valid and i < len(path) - 1:
        hop = path[i]
        nhop = path[i+1]
        valid = True if (nhop == hop + x_dim) or (nhop == hop - x_dim) or (nhop == hop + 1) or (nhop == hop - 1) else False
        i += 1
    return valid

def find_path_x_y(x_dim, curr_x, curr_y, dest_x, dest_y, path):
    """
    Recursively find path to a destination using x-y-routing.
    """
    path.append(x_dim * curr_y + curr_x)
    if curr_x == dest_x:
        if curr_y == dest_y:
            return path
        elif curr_y < dest_y:
            curr_y += 1
        else:
            curr_y -= 1
    elif curr_x < dest_x:
        curr_x += 1
    else:
        curr_x -= 1
    return find_path_x_y(x_dim, curr_x, curr_y, dest_x, dest_y, path)

def find_path_y_x(x_dim, curr_x, curr_y, dest_x, dest_y, path):
    """
    Recursively find path to a destination using y-x-routing.
    """
    path.append(x_dim * curr_y + curr_x)
    if curr_y == dest_y:
        if curr_x == dest_x:
            return path
        elif curr_x < dest_x:
            curr_x += 1
        else:
            curr_x -= 1
    elif curr_y < dest_y:
        curr_y += 1
    else:
        curr_y -= 1
    return find_path_y_x(x_dim, curr_x, curr_y, dest_x, dest_y, path)

def find_path_A(x_dim, source, dest):
    """
    Find shortest path from any source to any destination using x-y-routing.
    """
    curr_x = source % x_dim
    curr_y = source // x_dim
    dest_x = dest % x_dim
    dest_y = dest // x_dim
    return find_path_x_y(x_dim, curr_x, curr_y, dest_x, dest_y, [])

def find_path_B(x_dim, y_dim, source, dest):
    """
    Find alternative path from any source to any destination.
    In case the destination is in the same row or column, the first step
    must be away from that row or column in order to create a path disjoint
    from the first one.
    The step is made towards the closer edge of the NoC, if possible. In
    case a step is made in x-direction, y-x-routing is used afterwards,
    otherwise x-y-routing is used.
    """
    curr_x = source % x_dim
    curr_y = source // x_dim
    dest_x = dest % x_dim
    dest_y = dest // x_dim
    path = []
    if curr_x != dest_x and curr_y != dest_y:
        return find_path_y_x(x_dim, curr_x, curr_y, dest_x, dest_y, path)
    else:
        path.append(x_dim * curr_y + curr_x)
        if curr_x == dest_x and curr_y == dest_y:
            return path
        elif curr_x == dest_x:
            if curr_x <= x_dim // 2 and curr_x > 0 or curr_x == x_dim - 1:
                curr_x -= 1
            else:
                curr_x += 1
            return find_path_y_x(x_dim, curr_x, curr_y, dest_x, dest_y, path)
        else:
            if curr_y <= y_dim // 2 and curr_y > 0 or curr_y == y_dim - 1:
                curr_y -= 1
            else:
                curr_y += 1
            return find_path_x_y(x_dim, curr_x, curr_y, dest_x, dest_y, path)
