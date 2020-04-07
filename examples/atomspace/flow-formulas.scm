;
; flow-formulas.scm -- Dynamically changing flows.
;

(use-modules (opencog) (opencog exec))

; A formula for computing a SimpleTruthValue, based on two input Atoms.
; See the `formulas.scm` example for a detailed explanation of how
; this should be understood.
(DefineLink
   (DefinedPredicate "has a reddish color")
   (PredicateFormula
      (Minus
         (Number 1)
         (Times
            (StrengthOf (Variable "$X"))
            (StrengthOf (Variable "$Y"))))
      (Times
         (ConfidenceOf (Variable "$X"))
         (ConfidenceOf (Variable "$Y")))))

; Create an EvalationLink that will apply the formula above to a pair
; of Atoms. See the `formulas.scm` example for details.
(define evlnk
	(Evaluation
		(DefinedPredicate "has a reddish color")
		(List (Concept "A") (Concept "B"))))

; As in earlier examples, the TV on the EvaluationLink is recomputed
; every time that it is evaluated. We repeat this experiment here.
(cog-set-tv! (Concept "A") (stv 0.3 0.7))
(cog-set-tv! (Concept "B") (stv 0.4 0.6))
(cog-evaluate! evlnk)
(cog-tv evlnk)

; ----------
; The FormulaTruthValue is a kind of SimpleTruthValue, such that, every
; time that it is accessed, the current value -- that is, the current
; pair of floating point numbers -- is recomputed.  The recomputation
; is forced by calling evaluate on the Atom that the stream is created
; with. In this example, that means that the EvaluationLink, created
; above, will be evaluated, and the result of that evaluation (which
; is a SimpleTruthValue) is taken as the current numeric value of the
; stream. This is illustrated below.
;
; First, create the stream:
(define tv-stream (FormulaTruthValue evlnk))

; Print it out. Notice a sampling of the current numeric value, printed
; at the bottom:
(display tv-stream) (newline)

; Change one of the inputs, and notice the output tracks:
(cog-set-tv! (Concept "A") (stv 0.9 0.2))
(display tv-stream) (newline)

(cog-set-tv! (Concept "A") (stv 0.5 0.8))
(display tv-stream) (newline)

(cog-set-tv! (Concept "B") (stv 0.314159 0.9))
(display tv-stream) (newline)

; ----------
; This new kind of TV becomes interesting when it is used to
; automatically maintain the TV of some relationship. Suppose
; that A implied B, and the truth-probability of this is given
; by the formula above. So, first we write the implication:

(define a-implies-b (Implication (Concept "A") (Concept "B")))

; ... and then attach this auto-updating TV to it.
(cog-set-tv! a-implies-b tv-stream)

; Take a look at it, make sure that it is actually there.
(cog-tv a-implies-b)

; The above printed the "actual" TV, as it sits on the Atom.
; However, typically, we want the numeric values, and not the formula.
; These can be gotten simply by asking for them, directly, by name.
(format #t "A implies B has strength ~6F and confidence ~6F\n"
	(cog-mean a-implies-b) (cog-confidence a-implies-b))

; Change the TV on A and B ...
(cog-set-tv! (Concept "A") (stv 0.4 0.2))
(cog-set-tv! (Concept "B") (stv 0.7 0.8))

; ... and the TV on the implication stays current.
; Note that a different API is demoed below.
(format #t "A implies B has strength ~6F and confidence ~6F\n"
	(cog-tv-mean (cog-tv a-implies-b))
	(cog-tv-confidence (cog-tv a-implies-b)))

; ----------
; So far, the above is using a lot of scheme scaffolding to accomplish
; the setting of truth values. Can we do the same, without using scheme?
; Yes, we can. Just use the DynamicFormulaLink.  This is quite similar
; to the PredicateFormulaLink, demoed in `formulas.scm`, but in this
; case, instead of producing a single, static TV, this wraps the entire
; formula into a FormulasTruthValue. Thus, it is enough to set the TV
; only once; after that, the TV updates will be automatic.

; For example:
(cog-execute!
	(SetTV
		(Implication (Concept "A") (Concept "B"))
		(DynamicFormula
			(Minus
				(Number 1)
				(Times
					(StrengthOf (Concept "A"))
					(StrengthOf (Concept "B"))))
			(Times
				(ConfidenceOf (Concept "A"))
				(ConfidenceOf (Concept "B"))))))

; The above can be tedious, as it requires manually creating a new
; formula for each SetTV.  Some of this tedium can be avoided by
; using formulas with variables in them. Using the same formula as
; before, we get a dynamic example:
(DefineLink
   (DefinedPredicate "dynamic example")
   (DynamicFormula
      (Minus
         (Number 1)
         (Times
            (StrengthOf (Variable "$X"))
            (StrengthOf (Variable "$Y"))))
      (Times
         (ConfidenceOf (Variable "$X"))
         (ConfidenceOf (Variable "$Y")))))

; This can be used as anywhere any other predicate can be used;
; anywhere a PredicdeNode, GroundedPredicateNode, DefinedPredicate,
; or PredicateForumla can be used. They all provide the same utility:
; they provide a TruthValue.
(cog-execute!
	(SetTV
		(Implication (Concept "A") (Concept "B"))
		(DefinedPredicate "dynamic example")
		(List (Concept "A") (Concept "B"))))

; Double-check, as before:
(cog-tv a-implies-b)

; Change the TV on A and B ...
(cog-set-tv! (Concept "A") (stv 0.1 0.9))
(cog-set-tv! (Concept "B") (stv 0.1 0.9))

; And take another look.
(format #t "A implies B has strength ~6F and confidence ~6F\n"
	(cog-mean a-implies-b) (cog-confidence a-implies-b))

; -------------------------------------------------------------
; The FormulaStream is the generalization of FormulaTruthValue, suitable
; for streaming a FloatValue of arbitary length. As before, whenever it
; is accessed, the current vector value is recomputed. The recomputation
; forced by calling `execute()` on the Atom that the stream is created
; with.
;
; Create an Atom, a key, and a random stream of five numbers.
; The random stream is a FloatValue vector, of length 5; each of
; the numbers are randomly distributed between 0.0 and 1.0
(define foo (Concept "foo"))
(define bar (Concept "bar"))
(define akey (Predicate "some key"))
(define bkey (Predicate "other key"))

(cog-set-value! foo akey (RandomStream 5))

; Take a look at what was created.
(cog-value foo akey)

; Verify that it really is a vector, and that it changes with each
; access.
(cog-value->list (cog-value foo akey))
(cog-value->list (cog-value foo akey))
(cog-value->list (cog-value foo akey))

; Apply a formula to that stream, to get a different stream.
(define fstream (FormulaStream (Plus (Number 10) (ValueOf foo akey))))

; Place it on an atom, take a look at it, and make sure that it works.
(cog-set-value! bar bkey fstream)
(cog-value bar bkey)
(cog-value->list (cog-value bar bkey))
(cog-value->list (cog-value bar bkey))
(cog-value->list (cog-value bar bkey))

; ------- THE END -------
