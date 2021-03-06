#include "llvm/ADT/APFloat.h"
#include "llvm/ADT/APInt.h"
#include "llvm/Analysis/AliasAnalysis.h"
#include "llvm/Analysis/TargetLibraryInfo.h"
#include "llvm/Analysis/TargetTransformInfo.h"
#include "llvm/IR/Attributes.h"
#include "llvm/IR/LegacyPassManager.h"
#include "llvm/IR/DerivedTypes.h"
#include "llvm/IR/DIBuilder.h"
#include "llvm/IR/MDBuilder.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/GlobalValue.h"
#include "llvm/IR/InlineAsm.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/Metadata.h"
#include "llvm/IR/Module.h"
#include "llvm/Support/Casting.h"
#include "llvm/Support/FileSystem.h"
#include "llvm/Support/Host.h"
#include "llvm/Support/raw_ostream.h"
#include "llvm/Support/TargetRegistry.h"
#include "llvm/Support/TargetSelect.h"
#include "llvm/Target/TargetMachine.h"
#include "llvm/Target/TargetOptions.h"
#include "llvm/Transforms/IPO.h"
#include "llvm/Transforms/IPO/AlwaysInliner.h"
#include "llvm/Transforms/IPO/PassManagerBuilder.h"
#include "llvm/Transforms/InstCombine/InstCombine.h"

using namespace llvm;
using namespace llvm::sys;

extern "C"
void
Add_Debug_Flags (Module *TheModule)
{
  TheModule->addModuleFlag(Module::Warning, "Debug Info Version",
			   DEBUG_METADATA_VERSION);
  TheModule->addModuleFlag(Module::Warning, "Dwarf Version", 4);
}

extern "C"
DIEnumerator *
Create_Enumerator (DIBuilder *di, char *name, unsigned long long value,
		   bool isUnsigned)
{
  return di->createEnumerator (name, value, isUnsigned);
}

extern "C"
MDBuilder *
Create_MDBuilder_In_Context (LLVMContext &Ctx)
{
  return new MDBuilder (Ctx);
}

extern "C"
MDNode *
Create_TBAA_Root (MDBuilder *MDHelper)
{
  return MDHelper->createTBAARoot ("Ada Root");
}

extern "C"
void
Add_Cold_Attribute (Function *fn)
{
  fn->addFnAttr(Attribute::Cold);
}

extern "C"
void
Add_Dereferenceable_Attribute (Function *fn, unsigned idx,
			       unsigned long long Bytes)
{
  fn->addDereferenceableParamAttr (idx, Bytes);
}

extern "C"
void
Add_Ret_Dereferenceable_Attribute (Function *fn, unsigned long long Bytes)
{
  fn->addDereferenceableAttr (0, Bytes);
}

extern "C"
void
Add_Dereferenceable_Or_Null_Attribute (Function *fn, unsigned idx,
				       unsigned long long Bytes)
{
  fn->addDereferenceableOrNullParamAttr (idx, Bytes);
}

extern "C"
void
Add_Ret_Dereferenceable_Or_Null_Attribute (Function *fn, 
					  unsigned long long Bytes)
{
  fn->addDereferenceableOrNullAttr (0, Bytes);
}

extern "C"
void
Add_Inline_Always_Attribute (Function *fn)
{
  fn->addFnAttr(Attribute::AlwaysInline);
}

extern "C"
void
Add_Inline_Hint_Attribute (Function *fn)
{
  fn->addFnAttr(Attribute::InlineHint);
}

extern "C"
void
Add_Inline_No_Attribute (Function *fn)
{
  fn->addFnAttr(Attribute::NoInline);
}

extern "C"
void
Add_Named_Attribute (Function *fn, const char *name, const char *val,
		     LLVMContext &Ctx)
{
    fn->addFnAttr (Attribute::get (Ctx, StringRef (name, strlen (name)),
				   StringRef (val, strlen (val))));
}

extern "C"
void
Add_Nest_Attribute (Value *v, unsigned idx)
{
  if (Function *fn = dyn_cast<Function>(v))
    fn->addParamAttr (idx, Attribute::Nest);
  else if (CallInst *ci = dyn_cast<CallInst>(v))
    ci->addParamAttr (idx, Attribute::Nest);
  else if (InvokeInst *ii = dyn_cast<InvokeInst>(v))
    ii->addParamAttr (idx, Attribute::Nest);
}

extern "C"
void
Add_Noalias_Attribute (Function *fn, unsigned idx)
{
  fn->addParamAttr (idx, Attribute::NoAlias);
}

extern "C"
void
Add_Ret_Noalias_Attribute (Function *fn)
{
  fn->addAttribute (0, Attribute::NoAlias);
}

extern "C"
void
Add_Nocapture_Attribute (Function *fn, unsigned idx)
{
  fn->addParamAttr (idx, Attribute::NoCapture);
}

extern "C"
void
Add_Non_Null_Attribute (Function *fn, unsigned idx)
{
  fn->addParamAttr (idx, Attribute::NonNull);
}

extern "C"
void
Add_Ret_Non_Null_Attribute (Function *fn, unsigned idx)
{
  fn->addAttribute (0, Attribute::NonNull);
}

extern "C"
void
Add_Readonly_Attribute (Function *fn, unsigned idx)
{
  fn->addParamAttr (idx, Attribute::ReadOnly);
}

extern "C"
void
Add_Writeonly_Attribute (Function *fn, unsigned idx)
{
  fn->addParamAttr (idx, Attribute::WriteOnly);
}

extern "C"
MDNode *
Create_TBAA_Scalar_Type_Node (LLVMContext &ctx, MDBuilder *MDHelper,
			      const char *name, uint64_t size, MDNode *parent)
{
  Type *Int64 = Type::getInt64Ty (ctx);
  auto MDname = MDHelper->createString (name);
  auto MDsize = MDHelper->createConstant (ConstantInt::get (Int64, size));
  return MDNode::get(ctx, {parent, MDsize, MDname});
}

extern "C"
MDNode *
Create_TBAA_Struct_Type_Node (LLVMContext &ctx, MDBuilder *MDHelper,
			      const char *name, uint64_t size, int num_fields,
			      MDNode *parent, MDNode *fields[],
			      uint64_t offsets[], uint64_t sizes[])
{
  Type *Int64 = Type::getInt64Ty(ctx);
  SmallVector<Metadata *, 8> Ops (num_fields * 3 + 3);
  Ops [0] = parent;
  Ops [1] = MDHelper->createConstant (ConstantInt::get (Int64, size));
  Ops [2] = MDHelper->createString (name);
  for (unsigned i = 0; i < num_fields; i++)
    {
      Ops[3 + i * 3] = fields[i];
      Ops[3 + i * 3 + 1]
	  = MDHelper->createConstant (ConstantInt::get (Int64, offsets[i]));
      Ops[3 + i * 3 + 2]
	  = MDHelper->createConstant (ConstantInt::get (Int64, sizes[i]));
    }

  return MDNode:: get (ctx, Ops);
}

extern "C"
unsigned
Get_Stack_Alignment (DataLayout *dl)
{
  return dl->getStackAlignment ();
}

extern "C"
MDNode *
Create_TBAA_Access_Tag (MDBuilder *MDHelper, MDNode *BaseType,
			MDNode *AccessType, uint64_t offset, uint64_t size)
{
  return MDHelper->createTBAAAccessTag (BaseType, AccessType, offset, size,
					false);
}

extern "C"
void
Set_NUW (Instruction *inst)
{
  inst->setHasNoUnsignedWrap ();
}

extern "C"
void
Set_NSW (Instruction *inst)
{
  inst->setHasNoSignedWrap ();
}

extern "C"
void
Add_TBAA_Access (Instruction *inst, MDNode *md)
{
  inst->setMetadata (LLVMContext::MD_tbaa, md);
}

extern "C"
void
Set_DSO_Local (GlobalVariable *GV)
{
  GV->setDSOLocal (true);
}

/* Return nonnull if this value is a constant data.  */

extern "C"
Value *
Is_Constant_Data (Value *v)
{
  return dyn_cast<ConstantData> (v);
}

/* The LLVM C interface only provide single-index forms of extractvalue
   and insertvalue, so provide the multi-index forms here.  */

extern "C"
Value *
Build_Extract_Value_C (IRBuilder<> *bld, Value *aggr,
		       unsigned *IdxList, unsigned NumIdx, char *name)
{
  return bld->CreateExtractValue (aggr, makeArrayRef (IdxList, NumIdx), name);
}

extern "C"
Value *
Build_Insert_Value_C (IRBuilder<> *bld, Value *aggr, Value *elt,
		     unsigned *IdxList, unsigned NumIdx, char *name)
{
  return bld->CreateInsertValue (aggr, elt, makeArrayRef (IdxList, NumIdx),
				 name);
}

/* The LLVM C interface only provides a subset of the arguments for building
   memory copy/move/set, so we provide the full interface here.  */

extern "C"
Value *
Build_MemCpy (IRBuilder<> *bld, Value *Dst, unsigned DstAlign, Value *Src,
	      unsigned SrcAlign, Value *Size, bool isVolatile, MDNode *TBAATag,
	      MDNode *TBAAStructTag, MDNode *ScopeTag, MDNode *NoAliasTag)
{
  return bld->CreateMemCpy (Dst, DstAlign, Src, SrcAlign, Size, isVolatile,
			    TBAATag, TBAAStructTag, ScopeTag, NoAliasTag);
}

extern "C"
Value *
Build_MemMove (IRBuilder<> *bld, Value *Dst, unsigned DstAlign, Value *Src,
	       unsigned SrcAlign, Value *Size, bool isVolatile,
	       MDNode *TBAATag, MDNode *ScopeTag, MDNode *NoAliasTag)
{
  return bld->CreateMemMove (Dst, DstAlign, Src, SrcAlign, Size, isVolatile,
			     TBAATag, ScopeTag, NoAliasTag);
}

extern "C"
Value *
Build_MemSet (IRBuilder<> *bld, Value *Ptr, Value *Val, Value *Size,
	      unsigned align, bool isVolatile, MDNode *TBAATag,
	      MDNode *ScopeTag, MDNode *NoAliasTag)
{
  return bld->CreateMemSet (Ptr, Val, Size, align, isVolatile, TBAATag,
			    ScopeTag, NoAliasTag);
}

extern "C"
unsigned char
Does_Not_Throw (Function *fn)
{
  return fn->doesNotThrow () ? 1 : 0;
}

extern "C"
void
Set_Does_Not_Throw (Function *fn)
{
  return fn->setDoesNotThrow ();
}

extern "C"
void
Set_Does_Not_Return (Function *fn)
{
  return fn->setDoesNotReturn ();
}

/* The LLVM C interest Set_Volatile only works for loads and stores, not
   Atomic instructions.  */

extern "C"
void
Set_Volatile_For_Atomic (Instruction *inst)
{
  if (AtomicRMWInst *ARW = dyn_cast<AtomicRMWInst> (inst))
    return ARW->setVolatile(true);
  return cast<AtomicCmpXchgInst> (inst)->setVolatile(true);
}

extern "C"
void
Set_Weak_For_Atomic_Xchg (AtomicCmpXchgInst *inst)
{
  inst->setWeak(true);
}

extern "C"
void
Add_Function_To_Module (Function *f, Module *m)
{
  m->getFunctionList().push_back(f);
}

extern "C"
void
Inst_Add_Combine_Function (legacy::PassManager *PM, TargetMachine *TM)
{
  /* Create the minimum we need to run the InstructionCombining pass.
     We don't seem to be able to cache or delete any of these things without
     getting a SIGSEGV, so perhaps everything is already deleted for us.  */

  FunctionPass *CI = createInstructionCombiningPass (false);
  TargetLibraryInfoImpl TLII (TM->getTargetTriple ());
  TargetLibraryInfoWrapperPass *TLIP = new TargetLibraryInfoWrapperPass (TLII);

  PM->add (TLIP);
  PM->add (CI);
}

extern "C"
void
Dump_Metadata (MDNode *MD)
{
  MD->print (errs ());
}

extern "C"
unsigned
Get_Metadata_Num_Operands (MDNode *MD)
{
  return MD->getNumOperands ();
}

extern "C"
uint64_t
Get_Metadata_Operand_Constant_Value (MDNode *MD, unsigned i)
{
  return mdconst::extract<ConstantInt> (MD->getOperand (i))->getZExtValue ();
}

extern "C"
MDNode *
Get_Metadata_Operand (MDNode *MD, unsigned i)
{
  return dyn_cast<MDNode> (MD->getOperand (i));
}

extern "C"
void
Initialize_LLVM (void)
{
  // Initialize the target registry etc.  These functions appear to be
  // in LLVM.Target, but they reference static inline function, so they
  // can only be used from C, not Ada.

  InitializeAllTargetInfos();
  InitializeAllTargets();
  InitializeAllTargetMCs();
  InitializeAllAsmParsers();
  InitializeAllAsmPrinters();
}

extern "C"
void
LLVM_Optimize_Module (Module *M, TargetMachine *TM,
		      int Code_Opt_Level, int Size_Opt_Level, bool No_Inlining,
		      bool No_Unroll_Loops, bool No_Loop_Vectorization,
		      bool No_SLP_Vectorization, bool MergeFunctions,
		      bool PrepareForThinLTO, bool PrepareForLTO,
		      bool RerollLoops)
{
  legacy::PassManager Passes;
  std::unique_ptr<legacy::FunctionPassManager> FPasses;
  PassManagerBuilder Builder;

  TargetLibraryInfoImpl TLII(TM->getTargetTriple());

  Passes.add(new TargetLibraryInfoWrapperPass(TLII));

  // Add internal analysis passes from the target machine.
  Passes.add(createTargetTransformInfoWrapperPass (TM->getTargetIRAnalysis()));

  FPasses.reset(new legacy::FunctionPassManager(M));
  FPasses->add(createTargetTransformInfoWrapperPass
	       (TM ? TM->getTargetIRAnalysis() : TargetIRAnalysis()));

  Builder.OptLevel = Code_Opt_Level;
  Builder.SizeLevel = Size_Opt_Level;

  if (! No_Inlining && Code_Opt_Level > 1)
    Builder.Inliner
      = createFunctionInliningPass(Code_Opt_Level, Size_Opt_Level, false);
  else if (! No_Inlining)
    Builder.Inliner = createAlwaysInlinerLegacyPass();

  Builder.DisableUnrollLoops = Code_Opt_Level == 0 || No_Unroll_Loops;
  Builder.LoopsInterleaved = Code_Opt_Level != 0 && ! No_Unroll_Loops;
  Builder.LoopVectorize = (No_Loop_Vectorization ? false
			   : Code_Opt_Level > 1 && Size_Opt_Level < 2);

  Builder.SLPVectorize = (No_SLP_Vectorization ? false
			  : Code_Opt_Level > 1 && Size_Opt_Level < 2);

  Builder.MergeFunctions = Code_Opt_Level != 0 && MergeFunctions;
  Builder.PrepareForThinLTO = Code_Opt_Level != 0 && PrepareForThinLTO;
  Builder.PrepareForLTO = Code_Opt_Level != 0 && PrepareForLTO;
  Builder.RerollLoops = Code_Opt_Level != 0 && RerollLoops;

  TM->adjustPassManager(Builder);

  Builder.populateFunctionPassManager(*FPasses);
  Builder.populateModulePassManager(Passes);

  FPasses->doInitialization();
  for (Function &F : *M)
    FPasses->run(F);
  FPasses->doFinalization();

  Passes.run(*M);
}

extern "C"
Value *
Get_Float_From_Words_And_Exp (LLVMContext *Context, Type *T, int Exp,
			      unsigned NumWords, const uint64_t Words[])
{
  auto LongInt = APInt (NumWords * 64, makeArrayRef (Words, NumWords));
  auto Initial = APFloat (T->getFltSemantics (),
			  APInt::getNullValue(T->getPrimitiveSizeInBits()));
  Initial.convertFromAPInt(LongInt, false, APFloat::rmTowardZero);
  auto Result = scalbn (Initial, Exp, APFloat::rmTowardZero);
  return ConstantFP::get (*Context, Result);
}

extern "C"
Value *
Pred_FP (LLVMContext *Context, Type *T, Value *Val)
{
  // We want to compute the predecessor of Val, but the "next" function
  // can return unnormalized, so we have to multiply by one (adding zero
  // doesn't do it).
  auto apf = dyn_cast<ConstantFP>(Val)->getValueAPF ();
  auto one = APFloat (T->getFltSemantics (), 1);
  apf.next (true);
  apf.multiply(one, APFloat::rmTowardZero);
  return ConstantFP:: get (*Context, apf);
}

extern "C"
bool
Get_GEP_Constant_Offset (Value *GEP, DataLayout &dl, uint64_t *result)
{
  auto Offset = APInt (dl.getTypeAllocSize(GEP->getType()) * 8, 0);
  auto GEPO = dyn_cast<GEPOperator> (GEP);

  if (!GEPO || !GEPO->accumulateConstantOffset (dl, Offset)
      || !Offset.isIntN (64))
    return false;

  *result = Offset.getZExtValue ();
  return true;
}

extern "C"
int64_t
Get_Element_Offset (DataLayout &DL, StructType *ST, unsigned idx)
{
    const StructLayout *SL = DL.getStructLayout (ST);
    return SL->getElementOffset (idx);
}
