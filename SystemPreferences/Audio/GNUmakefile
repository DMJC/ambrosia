RPM_DISABLE_RELOCATABLE=YES

include $(GNUSTEP_MAKEFILES)/common.make

BUNDLE_NAME = AudioModule
BUNDLE_EXTENSION = .prefPane

AudioModule_HAS_RESOURCE_BUNDLE = yes

PIPEWIRE_CFLAGS := $(shell pkg-config --cflags libpipewire-0.3 2>/dev/null)
PIPEWIRE_LIBS   := $(shell pkg-config --libs   libpipewire-0.3 2>/dev/null)
PULSE_CFLAGS    := $(shell pkg-config --cflags libpulse        2>/dev/null)
PULSE_LIBS      := $(shell pkg-config --libs   libpulse        2>/dev/null)

ADDITIONAL_OBJCCFLAGS += $(PIPEWIRE_CFLAGS) $(PULSE_CFLAGS)

AudioModule_OBJCC_FILES = \
	AudioModule.mm \
	PulseAudioBackend.mm \
	PipeWireBackend.mm

AudioModule_PRINCIPAL_CLASS = AudioModule

AudioModule_RESOURCE_FILES = \
Audio.tiff \
Resources/English.lproj

AudioModule_FRAMEWORKS = PreferencePanes
AudioModule_LANGUAGES = \
Resources/English

ifeq ($(findstring darwin, $(GNUSTEP_TARGET_OS)), darwin)
  ADDITIONAL_GUI_LIBS += -lGSPreferencePanes $(PULSE_LIBS) $(PIPEWIRE_LIBS)
else
  ADDITIONAL_FRAMEWORK_DIRS += $(GNUSTEP_LOCAL_DOMAIN_ROOT)
  ADDITIONAL_GUI_LIBS += -lPreferencePanes $(PULSE_LIBS) $(PIPEWIRE_LIBS)
endif

include $(GNUSTEP_MAKEFILES)/bundle.make

-include GNUmakefile.preamble
-include GNUmakefile.postamble
