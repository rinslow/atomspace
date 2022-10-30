/*
 * Commands.cc
 * Fast command interpreter for basic AtomSpace commands.
 *
 * Copyright (C) 2020 Linas Vepstas
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Affero General Public License v3 as
 * published by the Free Software Foundation and including the exceptions
 * at http://opencog.org/wiki/Licenses
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU Affero General Public License
 * along with this program; if not, write to:
 * Free Software Foundation, Inc.,
 * 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
 */

#include <time.h>

#include <functional>
#include <iomanip>
#include <string>

#include <opencog/atoms/atom_types/NameServer.h>
#include <opencog/atoms/base/Link.h>
#include <opencog/atoms/base/Node.h>
#include <opencog/atoms/value/FloatValue.h>
#include <opencog/atoms/truthvalue/TruthValue.h>
#include <opencog/atomspace/AtomSpace.h>
#include <opencog/atomspace/version.h>

#include "Commands.h"
#include "Sexpr.h"

using namespace opencog;

/// The cogserver provides a network API to send/receive Atoms over
/// the internet. The actual API is that of the StorageNode (see the
/// wiki page https://wiki.opencog.org/w/StorageNode for details.)
/// The cogserver supports the full `StorageNode` API, and it uses
/// the code in this directory in order to make it fast.
///
/// To aid in performance, a very special set of about 15 scheme
/// functions have been hard-coded in C++, in the static function
/// `Commands::interpret_command()` below.  The goal is to avoid the
/// overhead of entry/exit into guile. This works because the cogserver
/// is guaranteed to send only these commands, and no others.
//

Commands::Commands(void)
{
	_multi_space = false;
}

Commands::~Commands()
{
}

void Commands::set_base_space(const AtomSpacePtr& asp)
{
	_base_space = asp;
}

/// Search for optional AtomSpace argument in `cmd` at `pos`.
/// If none is found, then return `as`
AtomSpace*
Commands::get_opt_as(const std::string& cmd, size_t& pos)
{
	if (not _multi_space) return _base_space.get();

	pos = cmd.find_first_not_of(" \n\t", pos);
	if (0 == cmd.compare(pos, 10, "(AtomSpace"))
	{
		_multi_space = true;
		Handle hasp = Sexpr::decode_frame(
			HandleCast(top_space), cmd, pos, _space_map);
		return (AtomSpace*) hasp.get();
	}
	return _base_space.get();
}

// -----------------------------------------------
// (cog-atomspace)
std::string Commands::cog_atomspace(const std::string& arg)
{
	if (not top_space) return "()";
	return top_space->to_string("");
}

// -----------------------------------------------
// (cog-atomspace-clear)
std::string Commands::cog_atomspace_clear(const std::string& arg)
{
	_base_space->clear();
	return "#t";
}

// -----------------------------------------------
// (cog-execute-cache! (GetLink ...) (Predicate "key") ...)
// This is complicated, and subject to change...
std::string Commands::cog_execute_cache(const std::string& cmd)
{
	size_t pos = 0;
	Handle query = Sexpr::decode_atom(cmd, pos, _space_map);
	query = _base_space->add_atom(query);
	Handle key = Sexpr::decode_atom(cmd, ++pos, _space_map);
	key = _base_space->add_atom(key);

	bool force = false;
	pos = cmd.find_first_of('(', pos);
	if (std::string::npos != pos)
	{
		Handle meta = Sexpr::decode_atom(cmd, pos, _space_map);
		meta = _base_space->add_atom(meta);

		// XXX Hacky .. store time in float value...
		_base_space->set_value(query, meta, createFloatValue((double)time(0)));
		if (std::string::npos != cmd.find("#t", pos))
			force = true;
	}
	ValuePtr rslt = query->getValue(key);
	if (nullptr != rslt and not force)
		return Sexpr::encode_value(rslt);

	// Run the query.
	if (query->is_executable())
		rslt = query->execute(_base_space.get());
	else if (query->is_evaluatable())
		rslt = ValueCast(query->evaluate(_base_space.get()));
	else
		return "#f";

	_base_space->set_value(query, key, rslt);

	return Sexpr::encode_value(rslt);
}

// -----------------------------------------------
// (cog-extract! (Concept "foo"))
std::string Commands::cog_extract(const std::string& cmd)
{
	size_t pos = 0;
	Handle h = _base_space->get_atom(Sexpr::decode_atom(cmd, pos, _space_map));
	if (nullptr == h) return "#t";
	if (_base_space->extract_atom(h, false)) return "#t";
	return "#f";
}

// -----------------------------------------------
// (cog-extract-recursive! (Concept "foo"))
std::string Commands::cog_extract_recursive(const std::string& cmd)
{
	size_t pos = 0;
	Handle h = _base_space->get_atom(Sexpr::decode_atom(cmd, pos, _space_map));
	if (nullptr == h) return "#t";
	if (_base_space->extract_atom(h, true)) return "#t";
	return "#f";
}

// -----------------------------------------------
// (cog-get-atoms 'Node #t)
std::string Commands::cog_get_atoms(const std::string& cmd)
{
	size_t pos = 0;
	Type t = Sexpr::decode_type(cmd, pos);

	pos = cmd.find_first_not_of(") \n\t", pos);
	bool get_subtypes = false;
	if (std::string::npos != pos and cmd.compare(pos, 2, "#f"))
		get_subtypes = true;

	// as = get_opt_as(cmd, pos, as);

	std::string rv = "(";
	HandleSeq hset;
	if (_multi_space and top_space)
		top_space->get_handles_by_type(hset, t, get_subtypes);
	else
		_base_space->get_handles_by_type(hset, t, get_subtypes);
	for (const Handle& h: hset)
		rv += Sexpr::encode_atom(h, _multi_space);
	rv += ")";
	return rv;
}

// -----------------------------------------------
// (cog-incoming-by-type (Concept "foo") 'ListLink)
std::string Commands::cog_incoming_by_type(const std::string& cmd)
{
	size_t pos = 0;
	Handle h = Sexpr::decode_atom(cmd, pos, _space_map);
	pos++; // step past close-paren
	Type t = Sexpr::decode_type(cmd, pos);

	AtomSpace* as = get_opt_as(cmd, pos);
	h = as->add_atom(h);

	std::string alist = "(";
	for (const Handle& hi : h->getIncomingSetByType(t))
		alist += Sexpr::encode_atom(hi);

	alist += ")";
	return alist;
}

// -----------------------------------------------
// (cog-incoming-set (Concept "foo"))
std::string Commands::cog_incoming_set(const std::string& cmd)
{
	size_t pos = 0;
	Handle h = Sexpr::decode_atom(cmd, pos, _space_map);
	AtomSpace* as = get_opt_as(cmd, pos);
	h = as->add_atom(h);
	std::string alist = "(";
	for (const Handle& hi : h->getIncomingSet())
		alist += Sexpr::encode_atom(hi);

	alist += ")";
	return alist;
}

// -----------------------------------------------
// (cog-keys->alist (Concept "foo"))
std::string Commands::cog_keys_alist(const std::string& cmd)
{
	size_t pos = 0;
	Handle h = Sexpr::decode_atom(cmd, pos, _space_map);
	AtomSpace* as = get_opt_as(cmd, pos);
	h = as->add_atom(h);

	std::string alist = "(";
	for (const Handle& key : h->getKeys())
	{
		alist += "(" + Sexpr::encode_atom(key) + " . ";
		alist += Sexpr::encode_value(h->getValue(key)) + ")";
	}
	alist += ")";
	return alist;
}

// -----------------------------------------------
// (cog-node 'Concept "foobar")
std::string Commands::cog_node(const std::string& cmd)
{
	size_t pos = 0;
	Type t = Sexpr::decode_type(cmd, pos);

	size_t l = pos+1;
	size_t r = cmd.size();
	std::string name = Sexpr::get_node_name(cmd, l, r, t);
	AtomSpace* as = get_opt_as(cmd, r);
	Handle h = as->get_node(t, std::move(name));

	if (nullptr == h) return "()";
	return Sexpr::encode_atom(h, _multi_space);
}

// -----------------------------------------------
// (cog-link 'ListLink (Atom) (Atom) (Atom))
std::string Commands::cog_link(const std::string& cmd)
{
	size_t pos = 0;
	Type t = Sexpr::decode_type(cmd, pos);

	HandleSeq outgoing;
	size_t l = pos+1;
	size_t r = cmd.size();
	while (l < r and ')' != cmd[l])
	{
		size_t l1 = l;
		size_t r1 = r;
		Sexpr::get_next_expr(cmd, l1, r1, 0);
		if (l1 == r1) break;
		outgoing.push_back(Sexpr::decode_atom(cmd, l1, r1, 0, _space_map));
		l = r1 + 1;
		pos = r1;
	}
	AtomSpace* as = get_opt_as(cmd, pos);
	Handle h = as->get_link(t, std::move(outgoing));

	if (nullptr == h) return "()";
	return Sexpr::encode_atom(h, _multi_space);
}

// -----------------------------------------------
// (cog-set-value! (Concept "foo") (Predicate "key") (FloatValue 1 2 3))
std::string Commands::cog_set_value(const std::string& cmd)
{
	size_t pos = 0;
	Handle atom = Sexpr::decode_atom(cmd, pos, _space_map);
	Handle key = Sexpr::decode_atom(cmd, ++pos, _space_map);
	ValuePtr vp = Sexpr::decode_value(cmd, ++pos);

	AtomSpace* as = get_opt_as(cmd, pos);
	atom = as->add_atom(atom);
	key = as->add_atom(key);
	if (vp)
		vp = Sexpr::add_atoms(as, vp);
	as->set_value(atom, key, vp);
	return "()";
}

// -----------------------------------------------
// (cog-set-values! (Concept "foo") (AtomSpace "foo")
//     (alist (cons (Predicate "bar") (stv 0.9 0.8)) ...))
std::string Commands::cog_set_values(const std::string& cmd)
{
	size_t pos = 0;
	Handle h = Sexpr::decode_atom(cmd, pos, _space_map);
	pos++; // skip past close-paren

	if (not _multi_space)
	{
		// Search for optional AtomSpace argument
		AtomSpace* as = get_opt_as(cmd, pos);
		h = as->add_atom(h);
	}
	Sexpr::decode_slist(h, cmd, pos);

	return "()";
}

// -----------------------------------------------
// (cog-set-tv! (Concept "foo") (stv 1 0))
// (cog-set-tv! (Concept "foo") (stv 1 0) (AtomSpace "foo"))
std::string Commands::cog_set_tv(const std::string& cmd)
{
	size_t pos = 0;
	Handle h = Sexpr::decode_atom(cmd, pos, _space_map);
	ValuePtr tv = Sexpr::decode_value(cmd, ++pos);

	// Search for optional AtomSpace argument
	AtomSpace* as = get_opt_as(cmd, pos);

	Handle ha = as->add_atom(h);
	if (nullptr == ha) return "()"; // read-only atomspace.
	as->set_truthvalue(ha, TruthValueCast(tv));
	return "()";
}

// -----------------------------------------------
// (cog-update-value! (Concept "foo") (Predicate "key") (FloatValue 1 2 3))
std::string Commands::cog_update_value(const std::string& cmd)
{
	size_t pos = 0;
	Handle atom = Sexpr::decode_atom(cmd, pos, _space_map);
	Handle key = Sexpr::decode_atom(cmd, ++pos, _space_map);
	ValuePtr vp = Sexpr::decode_value(cmd, ++pos);

	AtomSpace* as = get_opt_as(cmd, pos);
	atom = as->add_atom(atom);
	key = as->add_atom(key);

	if (not nameserver().isA(vp->get_type(), FLOAT_VALUE))
		return "()";

	FloatValuePtr fvp = FloatValueCast(vp);
	as->increment_count(atom, key, fvp->value());

	// Return the new value. XXX Why? This just wastes CPU?
	// ValuePtr vp = atom->getValue(key);
	// return Sexpr::encode_value(vp);
	return "()";
}

// -----------------------------------------------
// (cog-value (Concept "foo") (Predicate "key"))
std::string Commands::cog_value(const std::string& cmd)
{
	size_t pos = 0;
	Handle atom = Sexpr::decode_atom(cmd, pos, _space_map);
	Handle key = Sexpr::decode_atom(cmd, ++pos, _space_map);

	AtomSpace* as = get_opt_as(cmd, pos);
	atom = as->add_atom(atom);
	key = as->add_atom(key);

	ValuePtr vp = atom->getValue(key);
	return Sexpr::encode_value(vp);
}

// -----------------------------------------------
// (define sym (AtomSpace "foo" (AtomSpace "bar") (AtomSpace "baz")))
// Place the current atomspace at the bottom of the hierarchy.
std::string Commands::cog_define(const std::string& cmd)
{
	_multi_space = true;

	// Extract the symbolic name after the define
	size_t pos = 0;
	pos = cmd.find_first_not_of(" \n\t", pos);
	size_t epos = cmd.find_first_of(" \n\t", pos);
	// std::string sym = cmd.substr(pos, epos-pos);

	pos = epos+1;

	// Decode the AtomSpace frames
	Handle hasp = Sexpr::decode_frame(
		HandleCast(_base_space), cmd, pos, _space_map);
	top_space = AtomSpaceCast(hasp);

	// Hacky...
	// _space_map.insert({sym, top_space});

	return "()";
}

// -----------------------------------------------
// (ping) -- network ping
std::string Commands::cog_ping(const std::string& cmd)
{
	return "()";
}

// -----------------------------------------------
// (cog-version) -- AtomSpace version
std::string Commands::cog_version(const std::string& cmd)
{
	return ATOMSPACE_VERSION_STRING;
}

// ===================================================================
